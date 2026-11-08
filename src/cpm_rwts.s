; ---------------------------------------------------------------
; A2CB serial RWTS for Premium SoftCard IIe CP/M 2.26B.
;
; The PC (tools/cpm_serial.py) puts this in the boot image it
; serves, in place of the Disk II RWTS at $D500-$D69A. CP/M's own
; 6502 code is unchanged: it still calls $D500 with the IOB at
; $D69B-$D6A4 and the buffer at $4A/$4B, and $D6A5 still selects
; aux (Z80) memory and the $C07E window before calling here.
; Every sector is fetched from, or sent to, the PC through the
; Super Serial Card. See docs/CPM-SERIAL.md for the protocol.
;
; Entry points (fixed; the PC patches CP/M to reach the last two):
;   $D500  RWTS: command $D6A4 = 0 seek, 1 read, 2 write
;   $D503  format: refused as write protected ($10)
;   $D506  after the slot scan: report one Disk II (slot 6) and
;          hide the SSC, then continue at $D399
; Return: C clear, A = $D6A3 = 0; or C set, A = $D6A3 = $10/$40.
; ---------------------------------------------------------------
        .setcpu "6502"

iob_track  = $D69B
iob_sector = $D69C
iob_drive  = $D69F
iob_slot   = $D6A1
iob_status = $D6A3
iob_cmd    = $D6A4
buf        = $4A            ; and $4B, set by the caller
drives     = $E12B          ; drive count found by the slot scan
slot_type  = $E12B          ; + slot: card type per slot (2 = Disk II)
acia_data  = $C088          ; + SSC slot * 16
acia_stat  = $C089
acia_cmd   = $C08A
acia_ctrl  = $C08B

REQ        = $A5            ; request sync, Apple to PC
RSP        = $5A            ; response sync, PC to Apple
TRIES      = 3

        .segment "CODE"
        jmp     rwts
        jmp     format
        jmp     slotfix
cfg_slotx: .byte $20        ; patched by the PC: SSC slot * 16
cfg_ctrl:  .byte $10        ; patched by the PC: 6551 control (baud)
cfg_slot:  .byte $02        ; patched by the PC: SSC slot

hdr:       .byte REQ        ; request: sync, op (1 read, 2 write), unit, track, sector, seq, check
op:        .byte 0
unit:      .byte 0
track:     .byte 0
sector:    .byte 0
seq:       .byte 0
check:     .byte 0
try:       .byte 0
savesp:    .byte 0          ; stack pointer at attempt, for giving up from putb/getb
mask:      .byte 0
sum:       .word 0
t0:        .byte 0
t1:        .byte 0
t2:        .byte 0

rwts:   cld
        lda     iob_cmd
        bne     @io
        jmp     ok                  ; seek: nothing to move
@io:    cmp     #3
        bcc     @op
        jmp     format              ; anything else: write protected
@op:    sta     op
        lda     iob_slot
        and     #$70
        ora     iob_drive
        sta     unit
        lda     iob_track
        sta     track
        lda     iob_sector
        sta     sector
        lda     #TRIES
        sta     try

; One request and its reply. On a timeout putb and getb restore the
; stack pointer saved here and continue at retry.
attempt:
        tsx
        stx     savesp
        ldx     cfg_slotx
        lda     #$0B                ; no parity, no echo, no IRQ, RTS+DTR on
        sta     acia_cmd,x
        lda     cfg_ctrl
        sta     acia_ctrl,x
@drain: lda     acia_data,x         ; discard anything stale
        lda     acia_stat,x
        and     #$08
        bne     @drain
        inc     seq
        lda     #0                  ; check = XOR of the six bytes before it
        sta     check
        tay
@hdr:   lda     hdr,y
        jsr     putb
        eor     check
        sta     check
        iny
        cpy     #7
        bne     @hdr
        lda     op
        cmp     #2
        bne     reply
        jsr     clrsum              ; write: 256 bytes from the buffer, then their sum
@wr:    lda     (buf),y
        jsr     putb
        jsr     addsum
        iny
        bne     @wr
        lda     sum
        jsr     putb
        lda     sum+1
        jsr     putb

reply:  ldy     #0                  ; skip at most 256 stray bytes to the response sync
@sync:  jsr     getb
        cmp     #RSP
        beq     @head
        dey
        bne     @sync
        beq     retry
@head:  jsr     getb
        sta     iob_status
        jsr     getb
        cmp     seq
        bne     retry               ; a late reply to an earlier attempt
        lda     iob_status
        cmp     #$FE                ; the PC saw a damaged request: send it again
        beq     retry
        cmp     #0
        bne     fail
        lda     op
        cmp     #1
        bne     ok
        jsr     clrsum              ; read: 256 bytes into the buffer, then their sum
@rd:    lda     #0                  ; inline poll: about 66 cycles a byte at 115200 baud
        sta     t0
        sta     t1
@poll:  lda     acia_stat,x
        and     #$08
        bne     @got
        dec     t0
        bne     @poll
        dec     t1
        bne     @poll
        beq     retry               ; about 1 s without a byte
@got:   lda     acia_data,x
        sta     (buf),y
        jsr     addsum
        iny
        bne     @rd
        jsr     getb
        cmp     sum
        bne     retry
        jsr     getb
        cmp     sum+1
        bne     retry

ok:     lda     #0
        sta     iob_status
        clc
        rts

retry:  dec     try
        beq     ioerr
        jmp     attempt
ioerr:  lda     #$40
fail:   cmp     #$10                ; write protected; anything else is an I/O error
        beq     fail2
        lda     #$40
fail2:  sta     iob_status
        sec
        rts

format: lda     #$10                ; formatting a served image is refused
        bne     fail2

slotfix:                            ; replaces JMP $D399 at the end of the slot scan
        lda     #2
        sta     drives              ; one Disk II controller: two drives
        sta     slot_type+6         ; in slot 6
        ldx     cfg_slot
        lda     #0
        sta     slot_type,x         ; CP/M must not drive the SSC carrying the disks
        jmp     $D399

clrsum: lda     #0
        sta     sum
        sta     sum+1
        tay
        rts

addsum: pha                         ; sum += A, A kept
        clc
        adc     sum
        sta     sum
        bcc     :+
        inc     sum+1
:       pla
        rts

; putb: byte in A out of the SSC (A kept). getb: byte from the SSC into A.
; X = slot * 16. Both give up through retry, after about 3 s.
putb:   pha
        lda     #$10
        jsr     wait
        pla
        sta     acia_data,x
        rts
getb:   lda     #$08
        jsr     wait
        lda     acia_data,x
        rts

wait:   sta     mask
        lda     #0
        sta     t0
        sta     t1
        lda     #3
        sta     t2
@poll:  lda     acia_stat,x
        and     mask
        bne     @ready
        dec     t0
        bne     @poll
        dec     t1
        bne     @poll
        dec     t2
        bne     @poll
        ldx     savesp              ; give up: unwind to attempt's stack level
        txs
        jmp     retry
@ready: rts
