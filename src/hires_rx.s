; A2HR managed receiver. vnIIc-inspired request/full-page design, separate from A2MC.
; Header bytes 3..5 are the bootstrap configuration ABI: slot, ACIA speed, auto.
;
; The receiver asks and the PC answers; nothing is sent to it unasked. After the
; PC's 'H' it asks with a status byte and then $90,1,1. The status byte is
; $A0 + 4 * (hidden page: 0 = $2000, 1 = $4000) + what became of the last page:
;   0 nothing to say yet   1 shown   2 refused, hidden page untouched
;   3 refused, hidden page spoiled
; A version 1 PC ignores that byte and still reads $90,1,1. The PC answers with
;   0                                stop: restore text and 19200 baud
;   'H'                              start again at a clean boundary
;   1, 8192 bytes, XOR               a raw page into the hidden page
;   2, length (2), payload, XOR, SUM a packed page, version 2
; and the hidden page is shown only when its checks pass. A packed page waits in
; a buffer until both checks pass, so a damaged one never touches either page.
; Its payload rewrites the hidden page from $x000 on with tokens, the top two
; bits naming the kind and the low six a count less one:
;   00 literal: count bytes follow      01 skip: leave count bytes as they are
;   10 run: one byte follows, written count times
;   11 pair: two bytes follow, written alternately, count pairs
; Bytes after the last token are left as they are. A stream that would write past
; the page, or run past its own end, is refused.
;
; Keys pressed on the IIe go to the PC as their ASCII value (always below $80)
; whenever the receiver is waiting for a byte. Esc quits, even inside a page.
; If no byte arrives for about 0.75 s inside a page, the page is given up; after
; any refused page the line is read until it has been quiet for about 0.25 s, so
; what was left of that page is never taken for a command.
        .setcpu "6502"

ptr     = $06               ; and $07: where the next byte goes
page    = $08               ; high byte of the hidden page: $20 or $40
sum     = $09               ; XOR of the bytes received
tmo     = $19               ; and $1A: idle count for the timeouts
count   = $1B               ; bytes the current token covers
vala    = $1C
valb    = $1D
status  = $1E               ; what the next request says of the last page
sum2    = $EB               ; packed pages: running total of sum after each byte
cnt     = $EC               ; and $ED: bytes still to come, counted up to zero
left    = $EE               ; and $EF: bytes of the page a packed stream may still cover
src     = $FA               ; and $FB: next byte of the packed payload
endp    = $FC               ; and $FD: the payload's end

wire    = $7000             ; a packed page waits here ($7000-$8FFE) until its checks pass
TMO     = $80               ; about 0.75 s without a byte inside a page
QUIET   = $2A               ; about 0.25 s of silence after a refused page

        .segment "CODE"
        jmp entry
slot:   .byte 2
speed:  .byte $10
auto:   .byte 0
index:  .byte 0
saved_sp: .byte 0
loop_sp: .byte 0
entry:
        tsx
        stx saved_sp
        jsr $FE93
        jsr $FE89
        sta $C000               ; 80STORE off
        sta $C00C               ; 40 columns
        sta $C006               ; external slot ROM
        sta $C05F               ; single hi-res
        bit $C051
        jsr $FC58
        lda #<banner
        ldy #>banner
        jsr print
        lda auto
        bne configured
        lda #2
        sta slot
        lda #<slot_prompt
        ldy #>slot_prompt
        jsr print
pick_slot:
        jsr key
        cmp #$0D
        beq pick_baud
        cmp #'1'
        bcc pick_slot
        cmp #'8'
        bcs pick_slot
        and #7
        sta slot
pick_baud:
        lda #<baud_prompt
        ldy #>baud_prompt
        jsr print
baud_key:
        jsr key
        cmp #'1'
        beq slow
        cmp #'2'
        bne baud_key
        lda #$10
        bne set_speed
slow:   lda #$1F
set_speed:
        sta speed
configured:
        lda slot
        cmp #1
        bcs :+
        jmp invalid
:       cmp #8
        bcc :+
        jmp invalid
:       asl
        asl
        asl
        asl
        sta index
        tax
        lda #$0B
        sta $C08A,x
        lda speed
        cmp #$10
        beq init
        cmp #$1F
        beq init
        jmp invalid
init:   sta $C08B,x
        lda #<waiting
        ldy #>waiting
        jsr print
        lda #$20
        sta page
        tsx
        stx loop_sp
hello:  jsr get
        cmp #'H'
        bne hello
fresh:  lda #0
        sta status
request:
        ldx loop_sp             ; a page given up from inside a subroutine leaves nothing behind
        txs
        lda page                ; $20 or $40: bit 2 of the status byte
        lsr
        lsr
        lsr
        lsr
        and #4
        ora status
        ora #$A0
        jsr put
        lda #$90
        jsr put
        lda #1
        jsr put
        jsr put
response:
        jsr get
        cmp #0
        bne :+
        jmp exit
:       cmp #'H'                ; reconnect at a clean request boundary
        beq fresh
        cmp #1
        beq raw
        cmp #2
        bne response
        jmp packed

; A raw page, straight into the hidden page. If it fails, that page is spoiled.
raw:    lda #0
        sta ptr
        sta sum
        lda page
        sta ptr+1
        ldy #0
        ldx index
@next:  lda #TMO
        sta tmo+1
@wait:  lda $C089,x
        and #8
        bne @got
        lda $C000
        bpl @idle
        jsr key_out
@idle:  inc tmo
        bne @wait
        dec tmo+1
        bne @wait
        jmp spoiled
@got:   lda $C088,x
        sta (ptr),y
        eor sum
        sta sum
        iny
        bne @next
        inc ptr+1
        lda ptr+1
        and #$1F
        bne @next
        jsr getto
        bcs @bad
        cmp sum
        beq show
@bad:   jmp spoiled             ; corrupt page stays hidden

; The hidden page is good: show it, and aim the next page at the other one.
show:   bit $C057
        bit $C052
        lda page
        cmp #$20
        bne show_two
        bit $C054
        lda #$40
        bne shown
show_two:
        bit $C055
        lda #$20
shown:  sta page
        bit $C050
        lda #1
        sta status
        jmp request

refused:
        lda #2                  ; the hidden page is as it was
        bne bad_page
spoiled:
        lda #3                  ; the hidden page is no longer known
bad_page:
        sta status
; Read the line until it has been quiet for a while, then ask again.
        ldx index
@again: lda #QUIET
        sta tmo+1
@wait:  lda $C089,x
        and #8
        beq @idle
        lda $C088,x             ; what is left of the bad page: thrown away
        jmp @again
@idle:  lda $C000
        bpl @nokey
        jsr key_out
@nokey: inc tmo
        bne @wait
        dec tmo+1
        bne @wait
        jmp request

; A packed page: into the buffer first, and applied only when both checks pass.
packed:
        jsr getto
        bcs refused
        sta cnt
        sta endp
        jsr getto
        bcs refused
        sta cnt+1
        cmp #>($2000)           ; longer than the buffer: not a page
        bcs refused
        ora cnt
        beq refused             ; nothing at all: not a page
        clc
        lda cnt+1
        adc #>wire
        sta endp+1              ; endp = wire + length
        sec                     ; cnt = -length, counted up to zero
        lda #0
        sbc cnt
        sta cnt
        lda #0
        sbc cnt+1
        sta cnt+1
        lda #0
        sta ptr
        sta sum
        sta sum2
        lda #>wire
        sta ptr+1
        ldy #0
        ldx index
@next:  lda #TMO
        sta tmo+1
@wait:  lda $C089,x
        and #8
        bne @got
        lda $C000
        bpl @idle
        jsr key_out
@idle:  inc tmo
        bne @wait
        dec tmo+1
        bne @wait
@no:    jmp refused
@got:   lda $C088,x
        sta (ptr),y
        eor sum
        sta sum
        clc
        adc sum2
        sta sum2
        iny
        bne @same
        inc ptr+1
@same:  inc cnt
        bne @next
        inc cnt+1
        bne @next
        jsr getto
        bcs @no
        cmp sum
        bne @no
        jsr getto
        bcs @no
        cmp sum2
        bne @no

; Both checks passed: apply the payload to the hidden page.
        lda #0
        sta src
        sta ptr
        sta left
        lda #>wire
        sta src+1
        lda page
        sta ptr+1
        lda #$20
        sta left+1
token:  lda src                 ; at the payload's end the page is done
        cmp endp
        lda src+1
        sbc endp+1
        bcc @more
        lda src
        cmp endp
        beq @done
        jmp spoiled             ; a token ran past the end: out of shape
@done:  jmp show
@more:  ldy #0
        lda (src),y
        inc src
        bne :+
        inc src+1
:       tax
        and #$3F
        sta count
        inc count               ; 1 to 64
        txa
        and #$C0
        beq @literal
        cmp #$40
        beq @skip
        cmp #$80
        beq @run
        lda (src),y             ; pair
        sta vala
        iny
        lda (src),y
        sta valb
        lda #2
        jsr step_src
        asl count               ; in bytes: 2 to 128
        jsr take
        ldy #0
@pair:  lda vala
        sta (ptr),y
        iny
        lda valb
        sta (ptr),y
        iny
        cpy count
        bne @pair
        beq @moved
@run:   lda (src),y
        sta vala
        lda #1
        jsr step_src
        jsr take
        ldy #0
        lda vala
@fill:  sta (ptr),y
        iny
        cpy count
        bne @fill
        beq @moved
@literal:
        jsr take
        ldy #0
@copy:  lda (src),y
        sta (ptr),y
        iny
        cpy count
        bne @copy
        lda count
        jsr step_src
        jmp @moved
@skip:  jsr take
@moved: clc
        lda ptr
        adc count
        sta ptr
        bcc @again
        inc ptr+1
@again: jmp token

; Take count bytes from what is left of the page; more than is left spoils it.
take:   sec
        lda left
        sbc count
        sta left
        lda left+1
        sbc #0
        sta left+1
        bcs :+
        jmp spoiled
:       rts
step_src:
        clc
        adc src
        sta src
        bcc :+
        inc src+1
:       rts

invalid:
        jmp exit
; Restore the serial speed expected by disk service and local text I/O.
exit:
        ldx index
        beq no_serial
        lda #$1F
        sta $C08B,x
        lda #$0B
        sta $C08A,x
no_serial:
        bit $C054
        bit $C051
        jsr $FE93
        jsr $FE89
        ldx saved_sp
        txs
        jmp $03D0

; Wait for a byte from the PC, however long it takes. Keys go to the PC meanwhile.
get:    ldx index
@wait:  lda $C089,x
        and #8
        bne @got
        lda $C000
        bpl @wait
        jsr key_out
        jmp @wait
@got:   lda $C088,x
        rts
; The same inside a page: carry set if nothing arrives in time.
getto:  ldx index
        lda #TMO
        sta tmo+1
@wait:  lda $C089,x
        and #8
        bne @got
        lda $C000
        bpl @idle
        jsr key_out
@idle:  inc tmo
        bne @wait
        dec tmo+1
        bne @wait
        sec
        rts
@got:   lda $C088,x
        clc
        rts
; A key is down (A, high bit set; X = slot index). Esc quits. Anything else is
; sent to the PC if the transmitter is free and dropped if it is not, so typing
; can never hold up a page. X and Y are kept.
key_out:
        bit $C010
        cmp #$9B
        bne :+
        jmp exit
:       pha
        lda $C089,x
        and #$10
        beq @busy
        pla
        and #$7F
        sta $C088,x
        rts
@busy:  pla
        rts
put:
        pha
put_wait:
        lda $C000
        cmp #$9B                ; Esc works even when the PC is not taking bytes
        bne :+
        bit $C010
        jmp exit
:       ldx index
        lda $C089,x
        and #$10
        beq put_wait
        pla
        sta $C088,x
        rts
key:
        lda $C000
        bpl key
        bit $C010
        and #$7F
        cmp #$1B
        bne :+
        jmp exit
:       rts
print:
        sta ptr
        sty ptr+1
        ldy #0
print_char:
        lda (ptr),y
        beq printed
        ora #$80
        jsr $FDED
        iny
        bne print_char
printed:rts
        .segment "RODATA"
banner: .byte "A2HR RX V7.14.1 (PACK+KEYS)",13,0
slot_prompt: .byte "SSC SLOT 1-7 (RETURN=2)",13,0
baud_prompt: .byte "SPEED: 1=19200 2=115200",13,0
waiting: .byte "WAITING FOR HI-RES / ESC QUITS",13,0
