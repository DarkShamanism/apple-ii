; A2TS: loader for the workshop's native test screens. ProDOS, BRUN at $6000.
;
; The portal's display test pack is four raw screen-memory files. This program
; shows them: it reads the one picked from the disk it was loaded from and
; switches the display to match.
;   1 LORES.COLOR  1024 bytes, text page 1. Read into a buffer first; only the
;   2 LORES.MONO   960 visible bytes are copied, so firmware's screen holes
;                  ($478-$47F and the like) are left as they were.
;   3 HIRES.MONO   8192 bytes, read straight into $2000-$3FFF.
;   4 DHGR.MONO    16384 bytes: auxiliary $2000-$3FFF first, then main. The
;                  auxiliary half is read with 80STORE, HIRES and PAGE2 on, so
;                  ProDOS itself writes it into auxiliary memory. Offered only
;                  when ProDOS reports a 128K IIe, IIc or IIgs.
; A file is looked for under the current prefix first, then in the top
; directory of the volume this program was loaded from (ProDOS's DEVNUM), so
; BRUN A2TS,S6,D2 finds its screens without a PREFIX command.
; Any key leaves a picture; Esc at the menu returns to BASIC.
        .setcpu "6502"

mli      = $BF00
devnum   = $BF30            ; unit of the last device ProDOS used: where this program came from
machid   = $BF98
cout     = $FDED
prbyte   = $FDDA
home     = $FC58
setvid   = $FE93            ; PR#0
setkbd   = $FE89            ; IN#0
basic    = $03D0            ; BASIC.SYSTEM re-entry
kbd      = $C000
kbdstrb  = $C010

iobuf    = $7000            ; ProDOS's buffer for the open file ($7000-$73FF)
stage    = $7400            ; a lo-res page waits here ($7400-$77FF)

ptr      = $06              ; and $07
dst      = $08              ; and $09

        .segment "CODE"
        jmp     entry

which:    .byte 0           ; 0-3: the screen picked
saved_sp: .byte 0
errcode:  .byte 0
count:    .byte 0

op_parms: .byte 3           ; OPEN
op_path:  .word fname
          .word iobuf
op_ref:   .byte 0
rd_parms: .byte 4           ; READ
rd_ref:   .byte 0
rd_buf:   .word 0
rd_len:   .word 0
rd_got:   .word 0
cl_parms: .byte 1           ; CLOSE
cl_ref:   .byte 0
ol_parms: .byte 2           ; ON_LINE
ol_unit:  .byte 0
          .word volume
volume:   .res 16
fname:    .res 16           ; the picked file's name, length first
path:     .res 48           ; /VOLUME/NAME, length first

entry:
        tsx
        stx     saved_sp
        jsr     setvid          ; plain 40-column I/O even if 80 columns were on
        jsr     setkbd
menu:
        jsr     text_mode
        jsr     home
        lda     #<m_menu
        ldy     #>m_menu
        jsr     print
pick:
        jsr     key
        cmp     #$1B
        beq     quit
        sec
        sbc     #'1'
        cmp     #4
        bcs     pick
        sta     which
        jsr     show_one
        jmp     menu
quit:
        jsr     text_mode
        jsr     home
        ldx     saved_sp
        txs
        jmp     basic

; Load the picked screen and show it until a key is pressed. A failure is said
; in text and also waits for a key.
show_one:
        lda     which
        asl
        asl
        asl
        asl                     ; names are sixteen bytes apart
        tax
        ldy     #0
@name:  lda     names,x
        sta     fname,y
        inx
        iny
        cpy     #16
        bne     @name
        lda     #<m_loading
        ldy     #>m_loading
        jsr     print
        jsr     print_name
        lda     which
        cmp     #3
        bne     @open
        lda     machid          ; 1011xxxx: a IIe, IIc or IIgs with 128K
        and     #$F0
        cmp     #$B0
        beq     @open
        lda     #<m_need128
        ldy     #>m_need128
        jsr     print
        jmp     key
@open:  jsr     open_file
        bcs     @fail
        lda     which
        cmp     #2
        bcc     @lores
        beq     @hires
        sta     $C001           ; 80STORE on: PAGE2 now banks memory, not the display
        bit     $C057           ; HIRES on, so that it banks $2000-$3FFF as well
        bit     $C055           ; PAGE2: auxiliary memory
        jsr     read_page
        bit     $C054           ; main memory again (BIT leaves carry and A alone)
        bcs     @unbank
        jsr     read_page
@unbank:
        sta     $C000           ; 80STORE off
        bcs     @close_fail
        jsr     close_file
        sta     $C00D           ; 80 columns, which double hi-res needs
        sta     $C05E           ; double hi-res on
        jmp     @graphics
@hires: jsr     read_page
        bcs     @close_fail
        jsr     close_file
@graphics:
        bit     $C057           ; hi-res
        bit     $C052           ; full screen
        bit     $C054           ; page 1
        bit     $C050           ; graphics
        jmp     key
@lores: lda     #<stage
        sta     rd_buf
        lda     #>stage
        sta     rd_buf+1
        lda     #$00
        sta     rd_len
        lda     #$04
        sta     rd_len+1
        jsr     read_file
        bcs     @close_fail
        jsr     close_file
        jsr     copy_lores
        bit     $C056           ; lo-res
        bit     $C052           ; full screen
        bit     $C054           ; page 1
        bit     $C050           ; graphics
        jmp     key
@close_fail:
        pha
        jsr     close_file
        pla
@fail:  sta     errcode
        jsr     text_mode
        lda     #<m_cannot
        ldy     #>m_cannot
        jsr     print
        jsr     print_name
        lda     #<m_err
        ldy     #>m_err
        jsr     print
        lda     errcode
        jsr     prbyte
        lda     #<m_hint
        ldy     #>m_hint
        jsr     print
        jmp     key

; Open the picked file. Carry clear and the reference numbers set, or carry
; set and ProDOS's error in A.
open_file:
        lda     #<fname         ; first as it is named: under the current prefix
        sta     op_path
        lda     #>fname
        sta     op_path+1
        jsr     mli
        .byte   $C8
        .word   op_parms
        bcc     @opened
        sta     errcode         ; kept in case the volume cannot be named either
        lda     devnum          ; then on the volume this program came from
        sta     ol_unit
        jsr     mli
        .byte   $C5
        .word   ol_parms
        bcs     @first_error
        lda     volume
        and     #$0F
        beq     @first_error
        sta     count
        ldx     #1
        lda     #'/'
        sta     path,x
        ldy     #0
@vol:   lda     volume+1,y
        inx
        sta     path,x
        iny
        cpy     count
        bne     @vol
        inx
        lda     #'/'
        sta     path,x
        ldy     #0
@file:  iny
        lda     fname,y
        inx
        sta     path,x
        cpy     fname
        bne     @file
        stx     path
        lda     #<path
        sta     op_path
        lda     #>path
        sta     op_path+1
        jsr     mli
        .byte   $C8
        .word   op_parms
        bcs     @done           ; A = ProDOS's error for the full name
@opened:
        lda     op_ref
        sta     rd_ref
        sta     cl_ref
        clc
@done:  rts
@first_error:
        lda     errcode
        sec
        rts

; Read exactly one hi-res page into $2000-$3FFF, wherever that is banked.
read_page:
        lda     #$00
        sta     rd_buf
        sta     rd_len
        lda     #$20
        sta     rd_buf+1
        sta     rd_len+1
; Read rd_len bytes to rd_buf. Carry set and an error in A when ProDOS refuses
; or the file is shorter than the screen ($4C, ProDOS's end of file).
read_file:
        jsr     mli
        .byte   $CA
        .word   rd_parms
        bcs     @done
        lda     rd_got
        cmp     rd_len
        bne     @short
        lda     rd_got+1
        cmp     rd_len+1
        bne     @short
        clc
        rts
@short: lda     #$4C
        sec
@done:  rts

close_file:
        jsr     mli
        .byte   $CC
        .word   cl_parms
        rts

; Copy the 960 visible bytes of the staged page to text page 1. The eight
; bytes that end each 128 are firmware's screen holes: they are passed over.
copy_lores:
        lda     #<stage
        sta     ptr
        sta     dst
        lda     #>stage
        sta     ptr+1
        lda     #$04
        sta     dst+1
        ldx     #4
@page:  ldy     #0
@byte:  tya
        and     #$7F
        cmp     #$78
        bcs     @hole
        lda     (ptr),y
        sta     (dst),y
@hole:  iny
        bne     @byte
        inc     ptr+1
        inc     dst+1
        dex
        bne     @page
        rts

; Back to 40-column text on page 1, with every switch a picture changed put back.
text_mode:
        bit     $C051           ; text
        bit     $C054           ; page 1
        bit     $C056           ; lo-res selected
        sta     $C05F           ; double hi-res off
        sta     $C00C           ; 40 columns
        sta     $C000           ; 80STORE off
        rts

key:
        lda     kbd
        bpl     key
        bit     kbdstrb
        and     #$7F
        rts

print_name:
        ldy     #0
@char:  iny
        lda     fname,y
        ora     #$80
        jsr     cout
        cpy     fname
        bne     @char
        rts

print:
        sta     ptr
        sty     ptr+1
        ldy     #0
@char:  lda     (ptr),y
        beq     @done
        ora     #$80
        jsr     cout
        iny
        bne     @char
@done:  rts

        .segment "RODATA"
; Sixteen bytes to a name: its length, the name, then padding.
names:  .byte 11,"LORES.COLOR",0,0,0,0
        .byte 10,"LORES.MONO",0,0,0,0,0
        .byte 10,"HIRES.MONO",0,0,0,0,0
        .byte 9,"DHGR.MONO",0,0,0,0,0,0
m_menu: .byte "A2TS LOADER V7.14.1",13
        .byte "WORKSHOP TEST SCREENS",13,13
        .byte "1 LO-RES COLOR",13
        .byte "2 LO-RES MONO",13
        .byte "3 HI-RES MONO",13
        .byte "4 DOUBLE HI-RES MONO (128K)",13,13
        .byte "PICK 1-4. ANY KEY LEAVES A PICTURE.",13
        .byte "ESC QUITS.",13,0
m_loading: .byte 13,"LOADING ",0
m_need128: .byte 13,"DOUBLE HI-RES NEEDS A 128K IIE, IIC",13
        .byte "OR IIGS. PRESS A KEY.",13,0
m_cannot: .byte 13,"CANNOT LOAD ",0
m_err:  .byte " ERR $",0
m_hint: .byte 13,"PUT THE FOUR SCREENS ON THIS DISK,",13
        .byte "BESIDE A2TS. PRESS A KEY.",13,0
