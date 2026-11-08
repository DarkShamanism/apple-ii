; ---------------------------------------------------------------
; A2CB: boot Premium SoftCard IIe CP/M 2.26B from the PC.
;
; RAM only: needs no disk drive. The launcher deposits this at
; $6000 through the Apple monitor (IN#n, Ctrl-A 14B) and runs it.
; Header bytes 3..5 are the bootstrap ABI: SSC slot, 6551 control
; byte for the fast rate, reserved. The launcher patches them.
;
; It does what the Disk II boot ROM would: track 0 sector 0 to
; $0800 and the 15 sectors the boot sector asks for to $0A00-$18FF.
; The PC serves that 4 KB boot image already patched to use the
; serial RWTS (src/cpm_rwts.s). Then CP/M's own boot code runs
; from $082C as if the ROM had loaded it from slot 6.
; Protocol: docs/CPM-SERIAL.md. Esc on the IIe gives up.
; ---------------------------------------------------------------
        .setcpu "6502"

ptr        = $3C            ; and $3D: load address
slotx      = $3E
cout       = $FDED
kbd        = $C000
kbdstrb    = $C010
acia_data  = $C088
acia_stat  = $C089
acia_cmd   = $C08A
acia_ctrl  = $C08B

REQ        = $A5
RSP        = $5A
OP_BOOT    = 3
OP_HELLO   = 4
SLOW       = $1E            ; 9600 8N1, the rate Ctrl-A 14B left
CPM_BOOT   = $082C          ; 2.26B boot sector, after its ROM load loop

        .segment "CODE"
        jmp     entry
cfg_slot:  .byte 2
cfg_ctrl:  .byte $10
cfg_spare: .byte 0

hdr:       .byte REQ        ; request: sync, op, unit, track, sector, seq, check
op:        .byte 0
           .byte 0, 0
arg:       .byte 0
seq:       .byte 0
check:     .byte 0
tries:     .byte 0
pages:     .byte 0
sum:       .word 0
t0:        .byte 0
t1:        .byte 0
t2:        .byte 0

entry:  cld
        sei
        ldy     #0
        jsr     print               ; banner
        lda     cfg_slot
        asl     a
        asl     a
        asl     a
        asl     a
        sta     slotx
        tax
        sta     acia_stat,x         ; programmed reset
        lda     #$0B                ; no parity, no echo, no IRQ, RTS+DTR on
        sta     acia_cmd,x
        lda     #SLOW
        sta     acia_ctrl,x

        ; Hello at 9600, naming the fast rate; the PC answers, then both switch.
        lda     #8
        sta     tries
@hello: lda     #OP_HELLO
        sta     op
        lda     cfg_ctrl
        sta     arg
        jsr     request
        bcc     @fast
        dec     tries
        bne     @hello
        ldy     #m_noreply-msgs
        jmp     give_up
@fast:  lda     cfg_ctrl
        sta     acia_ctrl,x
        ldy     #0                  ; about 0.3 s for the PC to change its rate
@pause: dey
        bne     @pause
        dec     t0
        bne     @pause

        ; The boot image: 16 pages, then their 16-bit sum.
        lda     #6
        sta     tries
@boot:  lda     #OP_BOOT
        sta     op
        lda     #0
        sta     arg
        jsr     request
        bcs     @again
        lda     #0
        sta     ptr
        sta     sum
        sta     sum+1
        lda     #$08
        sta     ptr+1
        lda     #16
        sta     pages
        ldy     #0
@byte:  jsr     getb
        bcs     @again
        sta     (ptr),y
        clc
        adc     sum
        sta     sum
        bcc     :+
        inc     sum+1
:       iny
        bne     @byte
        inc     ptr+1
        lda     ptr+1
        cmp     #$09                ; page $09 is not part of the boot image
        bne     :+
        inc     ptr+1
:       dec     pages
        bne     @byte
        jsr     getb
        bcs     @again
        cmp     sum
        bne     @again
        jsr     getb
        bcs     @again
        cmp     sum+1
        beq     @go
@again: dec     tries
        bne     @boot
        ldy     #m_image-msgs
        jmp     give_up

@go:    ldy     #m_boot-msgs
        jsr     print
        ldx     #$60                ; slot 6, as the Disk II ROM leaves it
        jmp     CPM_BOOT

; Send hdr (op, arg in the sector field), then wait for RSP, status, seq.
; C clear when the PC answered with status 0 to this request.
request:
@drain: lda     acia_data,x
        lda     acia_stat,x
        and     #$08
        bne     @drain
        inc     seq
        lda     #0
        sta     check
        tay
@hdr:   lda     hdr,y
        jsr     putb
        eor     check
        sta     check
        iny
        cpy     #7
        bne     @hdr
        ldy     #0
@sync:  jsr     getb
        bcs     @fail
        cmp     #RSP
        beq     @head
        dey
        bne     @sync
@fail:  sec
        rts
@head:  jsr     getb
        bcs     @fail
        pha
        jsr     getb
        tay
        pla
        bcs     @fail
        cpy     seq
        bne     @fail
        cmp     #1                  ; C clear only for status 0
        rts

putb:   pha
@wait:  lda     acia_stat,x
        and     #$10
        beq     @wait
        pla
        sta     acia_data,x
        rts

; Byte into A, C clear; C set after about 2 s, or at once if Esc is pressed.
getb:   lda     #0
        sta     t0
        sta     t1
        lda     #2
        sta     t2
@poll:  lda     acia_stat,x
        and     #$08
        bne     @got
        dec     t0
        bne     @poll
        lda     kbd
        cmp     #$9B                ; Esc
        beq     @esc
        dec     t1
        bne     @poll
        dec     t2
        bne     @poll
        sec
        rts
@got:   lda     acia_data,x
        clc
        rts
@esc:   sta     kbdstrb
        ldy     #m_esc-msgs
        jmp     give_up

give_up:
        jsr     print
        lda     #SLOW               ; leave the SSC as the monitor had it
        ldx     slotx
        sta     acia_ctrl,x
        cli
        jmp     $FF69               ; monitor prompt

print:  lda     msgs,y
        beq     @done
        ora     #$80
        jsr     cout
        iny
        bne     print
@done:  lda     #$8D
        jmp     cout

msgs:
m_banner:  .byte "A2CB BOOT V7.14.1",0
m_noreply: .byte "NO REPLY FROM THE PC: CHECK SLOT, CABLE, BAUD",0
m_image:   .byte "BOOT IMAGE NOT RECEIVED",0
m_esc:     .byte "STOPPED",0
m_boot:    .byte "STARTING CP/M",0
