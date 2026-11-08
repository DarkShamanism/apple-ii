; ---------------------------------------------------------------
; A2SC: Microsoft Premium SoftCard IIe hardware probe.
;
; RAM only: never reads or writes a disk. Load and run at $6000.
; Header bytes 3..5 are the bootstrap ABI: SSC slot (0 = scan),
; reserved, reserved. The launcher patches the slot in its copy.
;
; It repeats, step for step, what Premium CP/M 2.26B does with the
; card's control register at $C07E (see docs/SOFTCARD.md):
;   bit 0  Z80 out of reset (inferred)
;   bit 2  6502 aux $2000-$9FFF sees Z80 address XOR $8000
;   bit 6  Z80 runs; aux reads of $2000 return the request flag
; and records what the hardware actually does:
;   1. which aux pages each mode reaches (tags at offsets $F8-$FC)
;   2. Z80 start from reset, hold, and a 42 T-state counting loop
;      timed over 8 video frames ($C019)
;   3. the Z80 request (I register = 80h) and the zero-page mailbox
; The report goes to the SSC at 9600 8N1 and a summary to the 40
; column screen. The card is left with $C07E = 0 (Z80 in reset).
; Power-cycle the Apple afterwards: the language card is overwritten.
; ---------------------------------------------------------------
        .setcpu "6502"
        .import __KERNEL_LOAD__, __KERNEL_RUN__, __KERNEL_SIZE__

card       = $C07E
rdvblbar   = $C019
acia_data  = $C088          ; all four are + slot * $10
acia_stat  = $C089
acia_cmd   = $C08A
acia_ctrl  = $C08B

ptr        = $06            ; and $07: aux address used by the kernel
src        = $08            ; and $09: main address used by the kernel
count      = $0A            ; kernel copy length, 1-255
slotx      = $0B            ; slot * $10
sum        = $0C            ; and $0D: sum of report bytes before END
tmp        = $0E
tmpx       = $0F
scr        = $10            ; and $11: screen pointer
str        = $12            ; and $13: string pointer
off        = $14            ; tag offset within each page
fillff     = $15            ; nonzero: fill with $FF, not page numbers
fillx      = $1F            ; tags are page number EOR fillx
polls      = $16            ; and $17
flags      = $18            ; bit 0 serial dead, bit 1 VBL timeout, bit 2 request seen, bit 3 request cleared
tcount     = $19            ; and $1A
mode_i     = $1B
writer_i   = $1C
col        = $1D
first      = $1E            ; first request flag value read

buf        = $7000          ; page tags read back, indexed by page
buf2       = $7200          ; check bytes for the power-on tags
results    = $7100          ; Z80 E380h-E38Fh, then mailbox $44-$4B, then misc
mbx        = $7110
misc       = $7118          ; R0, R1, S01, V400, V401, count1 (2), count2 (2), base, post, sum (2)

        .segment "CODE"
        jmp     entry
cfg_slot:  .byte 0
cfg_auto:  .byte 0
cfg_spare: .byte 0
saved_p:   .byte 0
slot:      .byte 0

entry:  php
        pla
        sta     saved_p
        sei
        cld
        bit     $C082           ; ROM, language card write-protected
        sta     $C000           ; 80STORE off
        sta     $C002           ; RAMRD main
        sta     $C004           ; RAMWRT main
        sta     $C008           ; ALTZP main
        sta     $C00C           ; 40 columns
        sta     $C00E           ; primary character set
        sta     $C006           ; slot ROMs, for the SSC signature
        bit     $C054
        bit     $C051
        lda     #0
        sta     flags
        sta     sum
        sta     sum+1
        sta     fillx
        jsr     cls
        ldx     #0
        lda     #<s_banner
        ldy     #>s_banner
        jsr     show

        ; Refuse anything but a IIe: on a IIc, $C07E disables the IOU.
        lda     $FBB3
        cmp     #$06
        bne     not_iie
        lda     $FBC0
        beq     not_iie         ; IIc
        sec
        jsr     $FE1F           ; IIgs clears carry; a IIe ROM only returns
        bcc     not_iie
        jmp     is_iie
not_iie:
        ldx     #2
        lda     #<s_notiie
        ldy     #>s_notiie
        jsr     show
        lda     saved_p
        pha
        plp
        rts

is_iie: lda     card            ; read before any write, as found
        sta     misc+0
        jsr     serial_init
        jsr     lc_setup

        lda     #<s_banner
        ldy     #>s_banner
        jsr     ser_line
        lda     #<s_slot
        ldy     #>s_slot
        jsr     ser_str
        lda     slot
        jsr     ser_hex
        jsr     ser_crlf
        lda     #<s_id
        ldy     #>s_id
        jsr     ser_str
        lda     $FBB3
        jsr     ser_hex_sp
        lda     $FBC0
        jsr     ser_hex_sp
        lda     misc+0
        jsr     ser_hex
        jsr     ser_crlf

        ; Baseline: aux RAM as the card leaves it at power-on.
        jsr     aux_test
        sta     misc+9
        lda     #<s_base
        ldy     #>s_base
        jsr     ser_str
        lda     misc+9
        jsr     ser_hex
        jsr     ser_crlf
        lda     #0              ; power-on tags: page at $FC, page EOR $A5 at $FD
        sta     fillff
        sta     fillx
        lda     #$FC
        sta     off
        jsr     fill_all
        lda     #$A5
        sta     fillx
        lda     #$FD
        sta     off
        jsr     fill_all
        lda     #0
        sta     fillx
        ldx     #2
        lda     #<s_scr_base
        ldy     #>s_scr_base
        jsr     show
        lda     misc+9
        jsr     scr_hex

        jsr     map_test
        ldx     #3
        lda     #<s_scr_map
        ldy     #>s_scr_map
        jsr     show

        jsr     run_test
        jsr     report_run

        ; Leave the Z80 in reset and the IIe switches as found.
        lda     #$00
        sta     card
        jsr     aux_test
        sta     misc+10
        lda     #<s_post
        ldy     #>s_post
        jsr     ser_str
        lda     misc+10
        jsr     ser_hex
        jsr     ser_crlf
        jsr     read_poweron
        lda     #<s_pp
        ldy     #>s_pp
        jsr     ser_str
        jsr     ser_buf
        lda     sum             ; the sum covers every byte before END
        sta     misc+11
        lda     sum+1
        sta     misc+12
        lda     #<s_end
        ldy     #>s_end
        jsr     ser_str
        lda     misc+12
        jsr     ser_hex
        lda     misc+11
        jsr     ser_hex
        jsr     ser_crlf
        ldx     #6
        lda     #<s_scr_post
        ldy     #>s_scr_post
        jsr     show
        lda     misc+10
        jsr     scr_hex
        lda     flags
        and     #1
        beq     @sent
        ldx     #7
        lda     #<s_noserial
        ldy     #>s_noserial
        jsr     show
@sent:  ldx     #9
        lda     #<s_done
        ldy     #>s_done
        jsr     show
        ldx     #10
        lda     #<s_done2
        ldy     #>s_done2
        jsr     show
        sta     $C000
        sta     $C002
        sta     $C004
        sta     $C008
        bit     $C082
done:   jmp     done            ; ProDOS and the LC are gone: power-cycle

; ---------------------------------------------------------------
; Window map: clear four tag offsets in every mode, tag each page
; with its own number in one mode per offset, then read every
; offset back in every mode. Pages 0-1 go through ALTZP, the rest
; through RAMRD/RAMWRT. Reader page Q holding tag P means the
; writer's page P and the reader's page Q are the same RAM byte.
; ---------------------------------------------------------------
map_test:
        lda     #1
        sta     fillff
        ldx     #0
@clear: stx     mode_i
        lda     modes,x
        sta     card
        ldy     #0
@cloff: tya
        clc
        adc     #$F8
        sta     off
        tya
        pha
        jsr     fill_all
        pla
        tay
        iny
        cpy     #4
        bne     @cloff
        ldx     mode_i
        inx
        cpx     #4
        bne     @clear

        lda     #0
        sta     fillff
        ldx     #0
@tag:   stx     mode_i
        lda     modes,x
        sta     card
        txa
        clc
        adc     #$F8
        sta     off
        jsr     fill_all
        ldx     mode_i
        inx
        cpx     #4
        bne     @tag

        ldx     #0
@read:  stx     mode_i
        lda     modes,x
        sta     card
        lda     #0
        sta     writer_i
@rdoff: lda     writer_i
        clc
        adc     #$F8
        sta     off
        jsr     read_all
        lda     #'M'
        jsr     ser_put
        lda     mode_i
        ora     #'0'
        jsr     ser_put
        lda     writer_i
        ora     #'0'
        jsr     ser_put
        lda     #' '
        jsr     ser_put
        jsr     ser_buf
        inc     writer_i
        lda     writer_i
        cmp     #4
        bne     @rdoff
        jsr     read_poweron
        lda     #'P'
        jsr     ser_put
        lda     mode_i
        ora     #'0'
        jsr     ser_put
        lda     #' '
        jsr     ser_put
        jsr     ser_buf
        ldx     mode_i
        inx
        cpx     #4
        bne     @read
        rts

; Tag or clear offset 'off' in pages $00-$BF.
fill_all:
        ldx     off
        lda     fillff
        beq     @tags
        lda     #$FF
        sta     $C009           ; ALTZP: no stack use until it is off
        sta     $00,x
        sta     $0100,x
        sta     $C008
        jmp     k_fill
@tags:  lda     #$00
        eor     fillx
        tay                     ; tag for page 0
        lda     #$01
        eor     fillx           ; tag for page 1
        sta     $C009
        sty     $00,x
        sta     $0100,x
        sta     $C008
        jmp     k_fill

; Read the power-on tags; pages whose check byte is wrong were never
; tagged (random RAM) and are reported as $FF.
read_poweron:
        lda     #$FD
        sta     off
        jsr     read_all
        ldx     #0
@copy:  lda     buf,x
        sta     buf2,x
        inx
        cpx     #$C0
        bne     @copy
        lda     #$FC
        sta     off
        jsr     read_all
        ldx     #0
@check: lda     buf,x
        eor     #$A5
        cmp     buf2,x
        beq     @ok
        lda     #$FF
        sta     buf,x
@ok:    inx
        cpx     #$C0
        bne     @check
        rts

; Read offset 'off' of pages $00-$BF into buf.
read_all:
        ldx     off
        sta     $C009
        lda     $00,x
        ldy     $0100,x
        sta     $C008
        sta     buf
        sty     buf+1
        jmp     k_read

; ---------------------------------------------------------------
; Z80 run, hold, timing and request test (CP/M 2.26B sequence).
; ---------------------------------------------------------------
run_test:
        lda     #$05            ; Z80 E300h-FFFFh at aux $6300-$7FFF
        sta     card
        lda     #$00
        ldx     #$63
        jsr     set_ptr
        lda     #<z80stub
        ldy     #>z80stub
        jsr     set_src
        lda     #(z80stub_end - z80stub)
        sta     count
        jsr     k_to_aux
        lda     #$80            ; clear Z80 E380h-E38Fh
        ldx     #$63
        jsr     set_ptr
        lda     #<zeros
        ldy     #>zeros
        jsr     set_src
        lda     #16
        sta     count
        jsr     k_to_aux
        lda     #$01
        sta     card
        lda     #$04            ; Z80 0000h at aux $8000
        sta     card
        lda     #$00
        ldx     #$80
        jsr     set_ptr
        lda     #<jp_e300
        ldy     #>jp_e300
        jsr     set_src
        lda     #3
        sta     count
        jsr     k_to_aux
        lda     #$00
        sta     card
        lda     #$05
        sta     card
        lda     card            ; 2.26B reads it here too
        sta     misc+1
        sta     $C009           ; mailbox as 2.26B leaves it: $44 = $AA
        ldx     #7
        lda     #0
@mb:    sta     $44,x
        dex
        bne     @mb
        lda     #$AA
        sta     $44
        sta     $C008

        jsr     wait_frame
        lda     #$41            ; start: Z80 leaves reset at 0000h
        sta     card
        ldx     #8
@fr:    txa
        pha
        jsr     wait_frame
        pla
        tax
        dex
        bne     @fr
        lda     #$01            ; hold
        sta     card
        lda     #$05
        sta     card
        jsr     read_count
        lda     results
        sta     misc+5
        lda     results+1
        sta     misc+6
        jsr     wait_frame
        jsr     wait_frame
        jsr     read_count
        lda     results
        sta     misc+7
        lda     results+1
        sta     misc+8

        lda     #$04            ; patch JP loop -> phase 2 while held
        ldx     #$63
        jsr     set_ptr
        lda     #<(z80stub + 6)
        ldy     #>(z80stub + 6)
        jsr     set_src
        lda     #2
        sta     count
        jsr     k_to_aux
        lda     #$01
        sta     card
        lda     #$5A            ; mailbox byte the Z80 should see at 0045h
        sta     $C009
        sta     $45
        sta     $C008
        lda     #$00
        ldx     #$04
        jsr     set_ptr
        lda     #$C3            ; aux $0400 in mode 01
        jsr     k_poke
        lda     #$00
        ldx     #$20
        jsr     set_ptr
        lda     #$65            ; aux $2000 in mode 01; bit 7 clear, so RAM here
                                ; can never pass for the request flag
        jsr     k_poke
        jsr     k_peek
        sta     misc+2

        lda     #$41            ; resume into phase 2
        sta     card
        lda     #$01
        ldx     #$04
        jsr     set_ptr
        lda     #$D4            ; aux $0401 with the run bit set
        jsr     k_poke
        lda     #0
        sta     polls
        sta     polls+1
        jsr     k_status
        sta     first
@poll:  jsr     k_status
        bmi     @seen
        inc     polls
        bne     @poll
        inc     polls+1
        bne     @poll
        jmp     @after          ; no request in about 2.6 s
@seen:  lda     flags
        ora     #4
        sta     flags
        lda     #$01            ; hold and read the mailbox like 2.26B
        sta     card
        ldx     #7
@rd:    sta     $C009
        lda     $44,x
        sta     $C008
        sta     mbx,x
        dex
        bpl     @rd
        lda     #$A7            ; reply the Z80 should see at 0045h
        sta     $C009
        sta     $45
        sta     $C008
        lda     #$41
        sta     card
        lda     #0
        sta     tcount
        sta     tcount+1
@clr:   jsr     k_status
        bpl     @clear
        inc     tcount
        bne     @clr
        inc     tcount+1
        bne     @clr
        beq     @hold
@clear: lda     flags
        ora     #8
        sta     flags
@hold:  jsr     wait_frame
        jsr     wait_frame
        lda     #$01
        sta     card
@after: lda     #$05
        sta     card
        jsr     read_results
        lda     #$01
        sta     card
        lda     #$00
        ldx     #$04
        jsr     set_ptr
        jsr     k_peek
        sta     misc+3
        inc     ptr
        jsr     k_peek
        sta     misc+4
        rts

read_count:
        lda     #$80
        ldx     #$63
        jsr     set_ptr
        lda     #<results
        ldy     #>results
        jsr     set_src
        lda     #2
        sta     count
        jmp     k_from_aux

read_results:
        lda     #$80
        ldx     #$63
        jsr     set_ptr
        lda     #<results
        ldy     #>results
        jsr     set_src
        lda     #16
        sta     count
        jmp     k_from_aux

report_run:
        lda     #<s_r1
        ldy     #>s_r1
        jsr     ser_str
        lda     misc+1
        jsr     ser_hex
        jsr     ser_crlf
        lda     #<s_run
        ldy     #>s_run
        jsr     ser_str
        lda     misc+6
        jsr     ser_hex
        lda     misc+5
        jsr     ser_hex_sp
        lda     misc+8
        jsr     ser_hex
        lda     misc+7
        jsr     ser_hex_sp
        lda     flags
        jsr     ser_hex
        jsr     ser_crlf
        lda     #<s_s01
        ldy     #>s_s01
        jsr     ser_str
        lda     misc+2
        jsr     ser_hex
        jsr     ser_crlf
        lda     #<s_req
        ldy     #>s_req
        jsr     ser_str
        lda     first
        jsr     ser_hex_sp
        lda     polls+1
        jsr     ser_hex
        lda     polls
        jsr     ser_hex
        jsr     ser_crlf
        lda     #<s_mbx
        ldy     #>s_mbx
        jsr     ser_str
        ldx     #0
@m:     lda     mbx,x
        jsr     ser_hex
        inx
        cpx     #8
        bne     @m
        jsr     ser_crlf
        lda     #<s_zr
        ldy     #>s_zr
        jsr     ser_str
        ldx     #0
@z:     lda     results,x
        jsr     ser_hex
        inx
        cpx     #16
        bne     @z
        jsr     ser_crlf
        lda     #<s_v40
        ldy     #>s_v40
        jsr     ser_str
        lda     misc+3
        jsr     ser_hex_sp
        lda     misc+4
        jsr     ser_hex
        jsr     ser_crlf
        ; Screen: Z80 count, hold check, request and reply.
        ldx     #4
        lda     #<s_scr_run
        ldy     #>s_scr_run
        jsr     show
        lda     misc+6
        jsr     scr_hex
        lda     misc+5
        jsr     scr_hex
        lda     misc+5
        ora     misc+6
        bne     @ran
        lda     #<s_scr_norun
        ldy     #>s_scr_norun
        bne     @say
@ran:   lda     misc+8
        cmp     misc+6
        bne     @moved
        lda     misc+7
        cmp     misc+5
        bne     @moved
        lda     #<s_scr_held
        ldy     #>s_scr_held
        bne     @say
@moved: lda     #<s_scr_moved
        ldy     #>s_scr_moved
@say:   jsr     scr_str
        ldx     #5
        lda     #<s_scr_req
        ldy     #>s_scr_req
        jsr     show
        lda     flags
        and     #4
        beq     @noreq
        lda     #<s_scr_seen
        ldy     #>s_scr_seen
        jsr     scr_str
        lda     results+3
        jmp     scr_hex
@noreq: lda     #<s_scr_none
        ldy     #>s_scr_none
        jmp     scr_str

; Aux RAM write/read test at offset 0 of pages $20, $40, $80, $A0.
; Returns a bit mask of passing pages in A.
aux_test:
        lda     #0
        sta     tmp
        ldx     #3
@next:  stx     tmpx
        lda     #0
        sta     ptr
        lda     test_pages,x
        sta     ptr+1
        lda     #$A5
        jsr     k_poke
        jsr     k_peek
        cmp     #$A5
        bne     @fail
        lda     #$5A
        jsr     k_poke
        jsr     k_peek
        cmp     #$5A
        bne     @fail
        ldx     tmpx
        lda     bits,x
        ora     tmp
        sta     tmp
@fail:  ldx     tmpx
        dex
        bpl     @next
        lda     tmp
        rts

set_ptr:
        sta     ptr
        stx     ptr+1
        rts
set_src:
        sta     src
        sty     src+1
        rts

; ---------------------------------------------------------------
; Video-frame timer: returns at the next start of vertical blank
; (RDVBLBAR bit 7 high to low). Flags a timeout instead of hanging.
; ---------------------------------------------------------------
wait_frame:
        lda     #0
        sta     tcount
        sta     tcount+1
@hi:    bit     rdvblbar
        bmi     @lo
        jsr     tick
        bcc     @hi
        rts
@lo:    bit     rdvblbar
        bpl     @done
        jsr     tick
        bcc     @lo
@done:  rts
tick:   inc     tcount
        bne     @ok
        inc     tcount+1
        bne     @ok
        lda     flags
        ora     #2
        sta     flags
        sec
        rts
@ok:    clc
        rts

; ---------------------------------------------------------------
; Language card: copy the monitor ROM (sane vectors), then switch
; to RAM bank 2 and install the aux-access kernel at $D000.
; Code that sets RAMRD runs there, because RAMRD would otherwise
; redirect this program's own instruction fetches.
; ---------------------------------------------------------------
lc_setup:
        bit     $C081
        bit     $C081           ; read ROM, write RAM bank 2
        lda     #$00
        sta     src
        lda     #$F8
        sta     src+1
        ldy     #0
@rom:   lda     (src),y
        sta     (src),y
        iny
        bne     @rom
        inc     src+1
        bne     @rom
        bit     $C083
        bit     $C083           ; read and write RAM bank 2
        ldy     #0
@k:     lda     __KERNEL_LOAD__,y
        sta     __KERNEL_RUN__,y
        iny
        cpy     #<__KERNEL_SIZE__
        bne     @k
        rts

; ---------------------------------------------------------------
; Serial: 9600 8N1, as left by Ctrl-A 14B. Without an SSC the
; probe still runs and shows its summary on screen.
; ---------------------------------------------------------------
serial_init:
        lda     cfg_slot
        and     #7
        bne     @have
        jsr     scan_ssc
        bne     @have
        lda     flags
        ora     #1
        sta     flags
        rts
@have:  sta     slot
        asl
        asl
        asl
        asl
        sta     slotx
        tax
        sta     acia_stat,x     ; programmed reset
        lda     #$0B            ; no parity, no echo, no IRQ, RTS+DTR on
        sta     acia_cmd,x
        lda     #$1E            ; 9600 8N1, internal generator
        sta     acia_ctrl,x
        lda     acia_data,x
        rts

; Slots 7..1: Pascal firmware signature of a Super Serial Card.
scan_ssc:
        lda     #$C7
        sta     str+1
        lda     #0
        sta     str
@chk:   ldy     #$05
        lda     (str),y
        cmp     #$38
        bne     @next
        ldy     #$07
        lda     (str),y
        cmp     #$18
        bne     @next
        ldy     #$0B
        lda     (str),y
        cmp     #$01
        bne     @next
        ldy     #$0C
        lda     (str),y
        cmp     #$31
        bne     @next
        lda     str+1
        and     #7
        rts
@next:  dec     str+1
        lda     str+1
        cmp     #$C0
        bne     @chk
        lda     #0
        rts

ser_put:
        sta     tmp
        stx     tmpx
        lda     flags
        and     #1
        bne     @out
        lda     tmp
        clc
        adc     sum
        sta     sum
        bcc     @sum
        inc     sum+1
@sum:   ldx     slotx
        lda     #0
        sta     tcount
        sta     tcount+1
@wait:  lda     acia_stat,x
        and     #$10
        bne     @send
        inc     tcount
        bne     @wait
        inc     tcount+1
        bne     @wait
        lda     flags           ; transmitter stuck: give up on serial
        ora     #1
        sta     flags
        bne     @out
@send:  lda     tmp
        sta     acia_data,x
@out:   ldx     tmpx
        lda     tmp
        rts

ser_hex_sp:
        jsr     ser_hex
        lda     #' '
        jmp     ser_put
ser_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr     @nib
        pla
        and     #$0F
@nib:   ora     #'0'
        cmp     #'9'+1
        bcc     @dig
        adc     #6
@dig:   jmp     ser_put
ser_crlf:
        lda     #13
        jsr     ser_put
        lda     #10
        jmp     ser_put
ser_line:
        jsr     ser_str
        jmp     ser_crlf
ser_str:
        sta     str
        sty     str+1
        ldy     #0
@c:     lda     (str),y
        beq     @x
        jsr     ser_put
        iny
        bne     @c
@x:     rts
; Send buf pages $00-$BF as hex, then CR LF.
ser_buf:
        ldx     #0
@b:     lda     buf,x
        jsr     ser_hex
        inx
        cpx     #$C0
        bne     @b
        jmp     ser_crlf

; ---------------------------------------------------------------
; 40-column screen, main text page 1. Only visible bytes are
; written: screen holes belong to slot firmware.
; ---------------------------------------------------------------
cls:    ldx     #23
@row:   jsr     row_addr
        ldy     #39
        lda     #$A0
@col:   sta     (scr),y
        dey
        bpl     @col
        dex
        bpl     @row
        rts
row_addr:
        txa
        and     #7
        lsr
        sta     scr+1
        lda     #0
        ror
        sta     scr
        txa
        and     #$18            ; (row / 8) * 40 = (row & $18) * 5
        sta     tmp
        asl
        asl
        clc
        adc     tmp
        clc
        adc     scr
        sta     scr
        lda     scr+1
        adc     #$04
        sta     scr+1
        lda     #0
        sta     col
        rts
; X = row, A/Y = string.
show:   pha
        jsr     row_addr
        pla
scr_str:
        sta     str
        sty     str+1
        ldy     #0
@c:     lda     (str),y
        beq     @x
        sty     tmp
        ldy     col
        ora     #$80
        sta     (scr),y
        inc     col
        ldy     tmp
        iny
        bne     @c
@x:     rts
scr_hex:
        pha
        lsr
        lsr
        lsr
        lsr
        jsr     @nib
        pla
        and     #$0F
@nib:   ora     #'0'
        cmp     #'9'+1
        bcc     @dig
        adc     #6
@dig:   ldy     col
        ora     #$80
        sta     (scr),y
        inc     col
        rts

        .segment "RODATA"
modes:      .byte $00, $01, $04, $05
test_pages: .byte $20, $40, $80, $A0
bits:       .byte $01, $02, $04, $08
jp_e300:    .byte $C3, $00, $E3
zeros:      .res 16, 0
z80stub:    .incbin "SC-PROBE-Z80.BIN"
z80stub_end:
s_banner:   .byte "A2SC PROBE V7.14.1",0
s_notiie:   .byte "NOT AN APPLE IIE: NOTHING CHANGED",0
s_slot:     .byte "SLOT ",0
s_id:       .byte "ID ",0
s_base:     .byte "BASE ",0
s_post:     .byte "POST ",0
s_pp:       .byte "PP ",0
s_r1:       .byte "R1 ",0
s_run:      .byte "RUN ",0
s_s01:      .byte "S01 ",0
s_req:      .byte "REQ ",0
s_mbx:      .byte "MBX ",0
s_zr:       .byte "ZR ",0
s_v40:      .byte "V40 ",0
s_end:      .byte "END ",0
s_scr_base: .byte "AUX RAM AT POWER-ON  ",0
s_scr_map:  .byte "WINDOW MAP SENT",0
s_scr_run:  .byte "Z80 COUNT ",0
s_scr_held: .byte " HOLD OK",0
s_scr_moved: .byte " NO HOLD",0
s_scr_norun: .byte " Z80 DID NOT RUN",0
s_scr_req:  .byte "REQUEST ",0
s_scr_seen: .byte "SEEN, REPLY ",0
s_scr_none: .byte "NOT SEEN",0
s_scr_post: .byte "AFTER RESTORE ",0
s_noserial: .byte "NO SERIAL OUTPUT (NO SSC?)",0
s_done:     .byte "DONE. RESULTS ARE ON THE PC.",0
s_done2:    .byte "POWER-CYCLE THE APPLE NOW.",0

; ---------------------------------------------------------------
; Aux-access kernel, run from language card RAM at $D000.
; ---------------------------------------------------------------
        .segment "KERNEL"
; Write a tag at offset 'off' of pages $02-$BF through RAMWRT:
; the page number EOR fillx, or $FF when fillff is set.
k_fill: lda     off
        sta     ptr
        ldx     #$02
        sta     $C005
@l:     stx     ptr+1
        txa
        eor     fillx
        ldy     fillff
        beq     @w
        lda     #$FF
@w:     ldy     #0
        sta     (ptr),y
        inx
        cpx     #$C0
        bne     @l
        sta     $C004
        rts
; Read offset 'off' of pages $02-$BF through RAMRD into buf.
k_read: lda     off
        sta     ptr
        ldx     #$02
        sta     $C003
@l:     stx     ptr+1
        ldy     #0
        lda     (ptr),y
        sta     buf,x
        inx
        cpx     #$C0
        bne     @l
        sta     $C002
        rts
; Copy count bytes from main (src) to aux (ptr).
k_to_aux:
        ldy     #0
        sta     $C005
@l:     lda     (src),y
        sta     (ptr),y
        iny
        cpy     count
        bne     @l
        sta     $C004
        rts
; Copy count bytes from aux (ptr) to main (src).
k_from_aux:
        ldy     #0
        sta     $C003
@l:     lda     (ptr),y
        sta     (src),y
        iny
        cpy     count
        bne     @l
        sta     $C002
        rts
; The 2.26B request poll: read aux $2000 (bit 7 = Z80 request).
k_status:
        sta     $C003
        lda     $2000
        sta     $C002
        rts
k_peek: sta     $C003
        ldy     #0
        lda     (ptr),y
        sta     $C002
        rts
k_poke: sta     $C005
        ldy     #0
        sta     (ptr),y
        sta     $C004
        rts
