        .setcpu "6502"

; ---------------------------------------------------------------
; A2MC lo-res receiver, v2
;
; BRUN at $1000 from ProDOS.
;
; - Scans slots 7..1 for a Super Serial Card (Pascal firmware
;   signature bytes); falls back to asking for a slot key 1-7.
; - Asks for speed: 1 = 19200, 2 = 115200. The 115200 mode uses
;   the 6551 "16x external clock" control value ($10), which is
;   how ADTPro runs an SSC at 115200.
; - Double buffered: each frame is received into the hidden
;   lo-res page ($400 or $800) and shown only when the XOR
;   checksum matches, so corrupted frames are dropped, not shown.
; - The screen stays in text mode showing the prompts until the
;   first complete good frame arrives.
; - Esc quits back to BASIC and puts the ACIA back to 19200 8N1
;   so VSDRIVE works again once ADTPro is restarted on the PC.
;
; Packet: A2 4D 43 01 + 1024 page-image bytes + XOR checksum.
; ---------------------------------------------------------------

cout       = $FDED
crout      = $FD8E
home       = $FC58
setvid     = $FE93          ; PR#0
setkbd     = $FE89          ; IN#0
basic_warm = $03D0          ; BASIC.SYSTEM re-entry

kbd        = $C000
kbdstrb    = $C010
speaker    = $C030
store80off = $C000          ; write: PAGE2 flips display pages, not aux memory
store80on  = $C001          ; write: PAGE2 banks aux memory at $400
col80off   = $C00C          ; write: 40-column display
col80on    = $C00D          ; write: 80-column display (needed for double lo-res)
slotcxrom  = $C006          ; write: real slot ROM at $C100-$C7FF, not IIe internal
dhireson   = $C05E          ; AN3 low: double-resolution graphics
dhiresoff  = $C05F          ; AN3 high: standard graphics

txtclr     = $C050
txtset     = $C051
mixclr     = $C052
lowscr     = $C054          ; show page 1 / bank main when 80STORE is on
hiscr      = $C055          ; show page 2 / bank aux when 80STORE is on
lores      = $C056
hires      = $C057

acia_data  = $C088          ; all four are + slot * $10
acia_stat  = $C089
acia_cmd   = $C08A
acia_ctrl  = $C08B

ptr        = $06            ; and $07
checksum   = $08
slot_index = $09            ; slot * $10
page_hi    = $0A            ; high byte of the page being received ($04/$08)
pages_left = $0B
scan_ptr   = $0C            ; and $0D
acia_live  = $0E            ; nonzero once the ACIA has been programmed
ctrl_val   = $0F            ; 6551 control value for the chosen speed
cand_slot  = $10            ; candidate slot during detection/confirm
ptr2       = $11            ; and $12: destination pointer (copy/decode)
frame_mode = $13            ; sync header: 1=lo-res 2=DLGR raw 3=RLE key 4=RLE delta
cur_mode   = $14            ; mode the soft switches are currently set up for
wlen       = $15            ; and $16: compressed payload length (counts down)
out_lo     = $17            ; decode output remaining, low byte
out_hi     = $18            ; decode output remaining, high byte
dirty      = $19            ; nonzero: frame buffer out of sync, deltas not shown
dpages     = $1A            ; bitmask of buffer pages the decode touched
mode_eor   = $1B            ; 0 = keyframe stores, nonzero = delta EORs
src_y      = $1C            ; decode source offset within current page
dst_y      = $1D            ; decode destination offset within current page
tok_n      = $1E            ; current token count

dlgr_buf   = $20            ; frame buffer $2000-$27FF, aux KB then main KB
wire_buf   = $28            ; compressed frames land at $2800+ (max 2303 bytes)

        .segment "CODE"

start:
        lda     #$00
        sta     acia_live
        sta     cur_mode
        sta     dpages
        lda     #$01
        sta     dirty           ; no frame-buffer base until a keyframe lands
        jsr     setvid          ; plain 40-column I/O even if 80-col was on
        jsr     setkbd
        sta     store80off
        sta     col80off
        sta     slotcxrom       ; scan real slot ROM, not internal firmware
        jsr     home

        lda     #<banner
        ldy     #>banner
        jsr     print_line

        jsr     find_ssc
        jsr     pick_speed
        jsr     init_serial

        lda     #<s_wait
        ldy     #>s_wait
        jsr     print_line

        lda     #$08            ; first frame lands on hidden page 2
        sta     page_hi

main_loop:
        jsr     wait_sync
        lda     frame_mode
        cmp     #$01
        beq     @lores
        cmp     #$05
        beq     @photo
        cmp     #$06
        beq     @tones
        cmp     #$02
        beq     @raw
        jmp     comp_frame      ; modes 3/4: compressed
@tones: jsr     recv_wire       ; same length+payload+checksum framing
        bne     main_loop       ; bad tones are just skipped, never shown
        jsr     play_tones
        jmp     main_loop
@lores: jsr     read_frame
        bne     main_loop       ; bad checksum: drop the frame
        jsr     show_frame
        jmp     main_loop
@photo: jsr     photo_rx
        jmp     main_loop
@raw:   jsr     read_dlgr
        bne     @rawbad
        lda     #$00
        sta     dirty           ; raw frame is a fresh delta base
        lda     #$FF
        sta     dpages
        jsr     show_dlgr
        jmp     main_loop
@rawbad:
        lda     #$01            ; partial overwrite: base is suspect
        sta     dirty
        jmp     main_loop

; ---------------------------------------------------------------
; Find the SSC: Pascal signature $38/$18/$01 at $Cn05/$Cn07/$Cn0B
; and device class $31 (serial) at $Cn0C, slots 7 down to 1 - and
; then prove a 6551 is really there by writing the control
; register and reading it back (an empty slot's floating bus
; cannot pass that). The result can be overridden by hand.
; ---------------------------------------------------------------
find_ssc:
        lda     #$00
        sta     scan_ptr
        lda     #$C7
        sta     scan_ptr+1
@check: ldy     #$05
        lda     (scan_ptr),y
        cmp     #$38
        bne     @next
        ldy     #$07
        lda     (scan_ptr),y
        cmp     #$18
        bne     @next
        ldy     #$0B
        lda     (scan_ptr),y
        cmp     #$01
        bne     @next
        ldy     #$0C
        lda     (scan_ptr),y
        cmp     #$31
        bne     @next
        lda     scan_ptr+1      ; firmware says serial; is the 6551 real?
        and     #$07
        jsr     acia_probe
        bcs     @found
@next:  dec     scan_ptr+1
        lda     scan_ptr+1
        cmp     #$C0
        bne     @check

        lda     #<s_noslot      ; no card matched: ask for the slot
        ldy     #>s_noslot
        jsr     print
@ask:   jsr     read_key
        cmp     #$9B            ; Esc
        beq     @quit
        cmp     #$B1            ; '1'
        bcc     @ask
        cmp     #$B8            ; past '7'
        bcs     @ask
        and     #$07
        bne     @have           ; always taken (1-7)

@found: lda     scan_ptr+1
        and     #$07
@have:  sta     cand_slot
        asl
        asl
        asl
        asl
        sta     slot_index
        jsr     crout
        lda     #<s_slot
        ldy     #>s_slot
        jsr     print
        lda     cand_slot
        ora     #$B0
        jsr     cout
        jsr     crout
        lda     #<s_confirm
        ldy     #>s_confirm
        jsr     print
@conf:  jsr     read_key
        cmp     #$8D            ; Return keeps the slot
        beq     @done
        cmp     #$9B            ; Esc
        beq     @quit
        cmp     #$B1
        bcc     @conf
        cmp     #$B8
        bcs     @conf
        and     #$07
        jmp     @have           ; chosen by hand: show it and re-confirm
@done:  jsr     crout
        rts
@quit:  jmp     quit

; ---------------------------------------------------------------
; A = slot 1-7. Carry set if a readable/writable 6551 control
; register lives at $C08B + slot*$10.
; ---------------------------------------------------------------
acia_probe:
        asl
        asl
        asl
        asl
        tax
        lda     #$55
        sta     acia_ctrl,x
        lda     acia_ctrl,x
        cmp     #$55
        bne     @no
        lda     #$AA
        sta     acia_ctrl,x
        lda     acia_ctrl,x
        cmp     #$AA
        bne     @no
        sec
        rts
@no:    clc
        rts

; ---------------------------------------------------------------
; Ask for the speed and remember the 6551 control value.
; ---------------------------------------------------------------
pick_speed:
        lda     #<s_speed
        ldy     #>s_speed
        jsr     print
@ask:   jsr     read_key
        cmp     #$9B            ; Esc
        beq     @quit
        cmp     #$B1            ; '1'
        beq     @slow
        cmp     #$B2            ; '2'
        bne     @ask
        lda     #$10            ; 115200: 16x external clock (ADTPro trick)
        sta     ctrl_val
        lda     #<s_fast
        ldy     #>s_fast
        jmp     print_line
@slow:  lda     #$1F            ; 19200 from the internal generator
        sta     ctrl_val
        lda     #<s_slow
        ldy     #>s_slow
        jmp     print_line
@quit:  jmp     quit

; ---------------------------------------------------------------
; Program the ACIA: reset, command $0B, chosen control value,
; then flush any stale receive byte.
; ---------------------------------------------------------------
init_serial:
        ldx     slot_index
        sta     acia_stat,x     ; programmed reset (written value ignored)
        lda     #$0B            ; no parity, no echo, no IRQ, RTS+DTR on
        sta     acia_cmd,x
        lda     ctrl_val
        sta     acia_ctrl,x
        lda     acia_data,x     ; flush receiver
        lda     acia_data,x
        lda     #$01
        sta     acia_live
        rts

; ---------------------------------------------------------------
; Wait for A2 4D 43 <mode>, mode 1 (lo-res, 1K) or 2 (double
; lo-res, 2K). A byte that breaks the chain is re-tested as a
; possible first sync byte so we cannot skip a real header.
; ---------------------------------------------------------------
wait_sync:
        jsr     serial_get
@s0:    cmp     #$A2
        bne     wait_sync
        jsr     serial_get
        cmp     #$4D            ; 'M'
        bne     @s0
        jsr     serial_get
        cmp     #$43            ; 'C'
        bne     @s0
        jsr     serial_get
        beq     @s0             ; zero is never a mode
        cmp     #$07
        bcs     @s0             ; accept modes 1-6 only
        sta     frame_mode
        rts

; ---------------------------------------------------------------
; read_frame: 1K lo-res frame into the hidden page (page_hi).
; read_dlgr: 2K double lo-res frame into the buffer at $2000.
; Both fall into recv_block: a tight polled loop that stores
; pages_left pages at (ptr) and then compares the trailing
; checksum byte. Returns with Z set if the frame is good. The
; polling paths also watch for Esc.
;
; Worst case is about 47 cycles per stored byte; a byte arrives
; every 89 cycles at 115200, and the 6551 buffers one more, so
; there is no overrun headroom problem.
; ---------------------------------------------------------------
read_frame:
        lda     page_hi
        sta     ptr+1
        lda     #$04
        sta     pages_left
        bne     recv_block      ; always

read_dlgr:
        lda     #dlgr_buf
        sta     ptr+1
        lda     #$08
        sta     pages_left

recv_block:
        lda     #$00
        sta     checksum
        sta     ptr
        ldx     slot_index
@page:  ldy     #$00
@poll:  lda     acia_stat,x
        and     #$08
        bne     @got
        lda     kbd
        bpl     @poll
        cmp     #$9B            ; Esc
        beq     @quit
        jsr     key_fwd         ; everything else goes to the PC
        jmp     @poll
@got:   lda     acia_data,x
        sta     (ptr),y
        eor     checksum
        sta     checksum
        iny
        bne     @poll
        inc     ptr+1
        dec     pages_left
        bne     @page
@cksum: lda     acia_stat,x
        and     #$08
        bne     @cgot
        lda     kbd
        bpl     @cksum
        cmp     #$9B
        beq     @quit
        jsr     key_fwd
        jmp     @cksum
@cgot:  lda     acia_data,x
        cmp     checksum
        rts
@quit:  jmp     quit

; ---------------------------------------------------------------
; A good lo-res frame just landed on the hidden page: make sure
; standard lo-res mode is set up, show that page, and aim the
; next frame at the other page.
; ---------------------------------------------------------------
show_frame:
        lda     cur_mode
        cmp     #$01
        beq     @flip
        sta     store80off      ; PAGE2 flips display pages again
        sta     col80off
        bit     dhiresoff       ; standard 40-wide lo-res
        lda     #$01
        sta     cur_mode
@flip:  bit     txtclr
        bit     mixclr
        bit     lores
        lda     page_hi
        cmp     #$08
        beq     @wrote2
        bit     lowscr          ; just filled page 1: show it
        lda     #$08
        sta     page_hi
        rts
@wrote2:
        bit     hiscr           ; just filled page 2: show it
        lda     #$04
        sta     page_hi
        rts

; ---------------------------------------------------------------
; A good double lo-res frame is in the buffer: make sure DLGR
; mode is set up (80-column, AN3 low, 80STORE banking), then copy
; the buffer pages flagged in dpages to the live text page.
; Buffer pages 0-3 are the aux KB, 4-7 the main KB. A full copy
; is about 20 ms; a small delta copies only what changed.
; ---------------------------------------------------------------
show_dlgr:
        lda     cur_mode
        cmp     #$02
        beq     @copy
        bit     lowscr          ; PAGE2 off before 80STORE turns on
        sta     store80on       ; PAGE2 now banks aux at $400
        sta     col80on
        bit     dhireson
        bit     txtclr
        bit     mixclr
        bit     lores
        lda     #$02
        sta     cur_mode
@copy:  ldx     #$00
@page:  lda     dpages
        and     bittab,x
        beq     @next
        cpx     #$04
        bcs     @main
        bit     hiscr           ; $400 writes go to aux
        bcc     @do             ; carry clear from cpx
@main:  bit     lowscr          ; $400 writes go to main
@do:    txa
        clc
        adc     #dlgr_buf
        sta     ptr+1           ; source page $20+x
        txa
        and     #$03
        clc
        adc     #$04
        sta     ptr2+1          ; destination page $04-$07
        lda     #$00
        sta     ptr
        sta     ptr2
        ldy     #$00
@byte:  lda     (ptr),y
        sta     (ptr2),y
        iny
        bne     @byte
@next:  inx
        cpx     #$08
        bne     @page
        lda     #$00
        sta     dpages
        rts

bittab: .byte   $01,$02,$04,$08,$10,$20,$40,$80

; ---------------------------------------------------------------
; Compressed frame (mode 3 = keyframe, 4 = XOR delta).
; Wire: len_lo len_hi, len compressed bytes, XOR checksum of them.
; Tokens: $01-$7F = run (next byte repeated n times),
;         $80-$FF = n-$7F literal bytes, $00 = invalid.
; A keyframe stores into the frame buffer; a delta EORs, and its
; zero-valued runs just skip ahead (nothing changed there).
; Any failure marks the buffer dirty; deltas are then decoded but
; not shown until a good keyframe (or raw frame) rebuilds it.
; ---------------------------------------------------------------
comp_frame:
        lda     frame_mode
        cmp     #$04
        beq     @eor
        lda     #$00
        beq     @setm           ; always
@eor:   lda     #$01
@setm:  sta     mode_eor
        jsr     recv_wire
        bne     @bad
        jsr     rle_decode
        bne     @bad
        lda     mode_eor
        bne     @delta
        lda     #$00            ; good keyframe: base is valid again
        sta     dirty
@delta: lda     dirty
        bne     @skip           ; wrong base: keep showing the old image
        jsr     show_dlgr
        jmp     main_loop
@skip:  lda     #$00            ; decoded but not shown: discard the marks
        sta     dpages
        jmp     main_loop
@bad:   lda     #$01
        sta     dirty
        jmp     main_loop

; ---------------------------------------------------------------
; Read the length header and the compressed payload into the wire
; buffer, then compare the trailing checksum. A=0 (Z set) if good.
; ---------------------------------------------------------------
recv_wire:
        jsr     serial_get
        sta     wlen
        jsr     serial_get
        sta     wlen+1
        cmp     #$09
        bcs     @fail           ; longer than the wire buffer: junk
        ora     wlen
        beq     @fail           ; zero length: junk
        lda     #$00
        sta     checksum
        sta     ptr
        lda     #wire_buf
        sta     ptr+1
        ldy     #$00
        ldx     slot_index
@poll:  lda     acia_stat,x
        and     #$08
        bne     @got
        lda     kbd
        bpl     @poll
        cmp     #$9B            ; Esc
        beq     @quit
        jsr     key_fwd
        jmp     @poll
@got:   lda     acia_data,x
        sta     (ptr),y
        eor     checksum
        sta     checksum
        iny
        bne     @low
        inc     ptr+1
@low:   lda     wlen            ; decrement remaining
        bne     @dec
        dec     wlen+1
@dec:   dec     wlen
        lda     wlen
        ora     wlen+1
        bne     @poll
@ck:    lda     acia_stat,x
        and     #$08
        bne     @cgot
        lda     kbd
        bpl     @ck
        cmp     #$9B
        beq     @quit
        jsr     key_fwd
        jmp     @ck
@cgot:  lda     acia_data,x
        cmp     checksum
        beq     @ok
        lda     #$01
        rts
@ok:    lda     #$00
        rts
@fail:  lda     #$01
        rts
@quit:  jmp     quit

; ---------------------------------------------------------------
; Expand the wire buffer into the frame buffer. Output is capped
; at exactly 2048 bytes and source reads may not leave the wire
; buffer's nine pages; anything out of shape returns A=1. A=0 on
; success. Pages touched by stores/EORs are flagged in dpages;
; zero-valued runs in delta mode skip without touching anything.
; ---------------------------------------------------------------
tok_v    = $1F              ; run value stash
mark_tmp = $05              ; X save inside mark_page

rle_decode:
        lda     #$00
        sta     ptr             ; source = wire buffer
        sta     ptr2            ; destination = frame buffer
        sta     src_y
        sta     dst_y
        sta     out_lo
        lda     #wire_buf
        sta     ptr+1
        lda     #dlgr_buf
        sta     ptr2+1
        lda     #$08            ; 2048 bytes = $0800
        sta     out_hi
        bne     @token          ; always (A=8)

@fail1: lda     #$01            ; near trampolines for the early branches
        rts
@lits1: jmp     @lits
@done1: lda     #$00
        rts

@token: lda     out_lo
        ora     out_hi
        beq     @done1          ; output complete

        ldy     src_y           ; ---- fetch token byte ----
        lda     (ptr),y
        inc     src_y
        bne     @tk
        inc     ptr+1
        ldy     ptr+1
        cpy     #$31            ; ran past the wire buffer
        bcs     @fail1
@tk:    cmp     #$00
        beq     @fail1          ; token $00 is invalid
        cmp     #$80
        bcs     @lits1

        ; ---- run token: A = count 1-127 ----
        sta     tok_n
        jsr     out_take
        bcc     @fail1

        ldy     src_y           ; ---- fetch run value ----
        lda     (ptr),y
        inc     src_y
        bne     @rv
        inc     ptr+1
        ldy     ptr+1
        cpy     #$31
        bcs     @fail1
@rv:    sta     tok_v
        ldx     mode_eor
        beq     @dorun          ; keyframes store everything
        cmp     #$00
        bne     @dorun
        lda     dst_y           ; zero-valued delta run: skip ahead
        clc
        adc     tok_n
        sta     dst_y
        bcc     @token
        inc     ptr2+1
        jmp     @token

@dorun: jsr     mark_page
        ldx     tok_n
        lda     mode_eor
        bne     @runeor
        lda     tok_v
        ldy     dst_y
@rs:    sta     (ptr2),y
        iny
        bne     @rsn
        inc     ptr2+1
        jsr     mark_page
        lda     tok_v
@rsn:   dex
        bne     @rs
        sty     dst_y
        jmp     @token

@runeor:
        ldy     dst_y
@re:    lda     tok_v
        eor     (ptr2),y
        sta     (ptr2),y
        iny
        bne     @ren
        inc     ptr2+1
        jsr     mark_page
@ren:   dex
        bne     @re
        sty     dst_y
        jmp     @token

        ; ---- literal token: count = A - $7F (1-128) ----
@lits:  sec
        sbc     #$7F
        sta     tok_n
        jsr     out_take
        bcc     @fail
        jsr     mark_page
        ldx     tok_n
        lda     mode_eor
        bne     @liteor

@ls:    ldy     src_y           ; literal store loop
        lda     (ptr),y
        inc     src_y
        bne     @ls1
        inc     ptr+1
        ldy     ptr+1
        cpy     #$31
        bcs     @fail
@ls1:   ldy     dst_y
        sta     (ptr2),y
        iny
        sty     dst_y
        bne     @ls2
        inc     ptr2+1
        jsr     mark_page
@ls2:   dex
        bne     @ls
        jmp     @token

@liteor:
@le:    ldy     src_y           ; literal EOR loop
        lda     (ptr),y
        inc     src_y
        bne     @le1
        inc     ptr+1
        ldy     ptr+1
        cpy     #$31
        bcs     @fail
@le1:   ldy     dst_y
        eor     (ptr2),y
        sta     (ptr2),y
        iny
        sty     dst_y
        bne     @le2
        inc     ptr2+1
        jsr     mark_page
@le2:   dex
        bne     @le
        jmp     @token

@done:  lda     #$00
        rts
@fail:  lda     #$01
        rts

; ---------------------------------------------------------------
; out_take: out -= tok_n. Carry clear means underflow (too much).
; ---------------------------------------------------------------
out_take:
        lda     out_lo
        sec
        sbc     tok_n
        sta     out_lo
        lda     out_hi
        sbc     #$00
        sta     out_hi
        rts

; ---------------------------------------------------------------
; Flag the frame-buffer page ptr2+1 points at. Preserves X and Y.
; ---------------------------------------------------------------
mark_page:
        stx     mark_tmp
        lda     ptr2+1
        and     #$07            ; $20-$27 -> bit 0-7
        tax
        lda     dpages
        ora     bittab,x
        sta     dpages
        ldx     mark_tmp
        rts

; ---------------------------------------------------------------
; Blocking serial read used while hunting for sync; checks Esc.
; ---------------------------------------------------------------
serial_get:
        ldx     slot_index
@wait:  lda     acia_stat,x
        and     #$08
        bne     @got
        lda     kbd
        bpl     @wait
        cmp     #$9B            ; Esc
        beq     @quit
        jsr     key_fwd
        jmp     @wait
@got:   lda     acia_data,x
        rts
@quit:  jmp     quit

; ---------------------------------------------------------------
; Forward a keypress (A = key, high bit set) to the PC over the
; ACIA transmitter. X must hold slot_index, which it does at all
; call sites. Dropped if the transmitter is busy: input is light
; and lossy so it can never stall the receive path.
; ---------------------------------------------------------------
key_fwd:
        sta     kbdstrb
        bit     speaker         ; soft key click
        pha
        lda     acia_stat,x
        and     #$10            ; transmit register empty?
        beq     @busy
        pla
        and     #$7F            ; plain ASCII
        sta     acia_data,x
        rts
@busy:  pla
        rts

; ---------------------------------------------------------------
; Mode 6 payload in the wire buffer: a count byte, then (N,T)
; pairs. N bits 0-6 set the pitch (half period = 19*N+20 cycles,
; so roughly 210 Hz up to 8 kHz); N bit 7 makes it a rest. Each
; entry plays 2*T half-cycles. The CPU owns the speaker for the
; whole packet - the PC pads its pacing gap to match, so the
; receive line is silent while this plays.
; ---------------------------------------------------------------
play_tones:
        lda     #$00
        sta     ptr
        lda     #wire_buf
        sta     ptr+1
        ldy     #$00
        lda     (ptr),y         ; entry count
        beq     @done
        sta     tok_n
        iny
@tone:  lda     (ptr),y         ; N (+ rest flag)
        sta     tok_v
        iny
        lda     (ptr),y         ; T
        iny
        asl                     ; 2*T half-cycles (T <= 127)
        sta     wlen
@half:  lda     tok_v
        bmi     @rest           ; rest: keep time, skip the toggle
        bit     speaker
@rest:  lda     tok_v
        and     #$7F
        tax
@delay: pha
        pla
        pha
        pla
        dex
        bne     @delay
        dec     wlen
        bne     @half
        dec     tok_n
        bne     @tone
@done:  rts

; ---------------------------------------------------------------
; Mode 5: photo. Two length bytes, then an RLE token stream that
; paints 8K onto the standard hi-res screen ($2000, main memory),
; progressively visible. Plain HGR works on every Apple II - no
; aux banking, no AN3 - chosen because double hi-res proved
; unavailable on this machine (text garbage instead of graphics).
; A flaw only costs pixels in a photo, so there is no checksum.
; $2000-$27FF doubles as the DLGR frame buffer, so the delta base
; is marked dirty; the PC sends a keyframe when video resumes.
; ---------------------------------------------------------------
photo_rx:
        lda     #$01
        sta     dirty
        sta     store80off      ; plain main-bank hi-res: every IIe can
        sta     col80off
        bit     dhiresoff
        bit     hires
        bit     txtclr
        bit     mixclr
        bit     lowscr
        lda     #$05
        sta     cur_mode
        jsr     serial_get      ; length, low then high
        sta     wlen
        jsr     serial_get
        sta     wlen+1
        ldx     slot_index
        lda     #$00
        sta     ptr2
        sta     dst_y
        lda     #$20
        sta     ptr2+1          ; output base $2000, main memory
        sta     pages_left      ; 32 pages = 8K
        bne     @token          ; always
@done0: rts

@token: lda     pages_left
        beq     @done0
        jsr     @wbyte          ; token
        beq     @done0          ; stream end (or zero token)
        cmp     #$80
        bcs     @lit
        sta     tok_n           ; run: count, then value
        jsr     @wbyte
        sta     tok_v
@run:   ldy     dst_y
        lda     tok_v
        sta     (ptr2),y
        iny
        sty     dst_y
        bne     @runn
        jsr     @page
        beq     @done
@runn:  dec     tok_n
        bne     @run
        jmp     @token

@lit:   sec
        sbc     #$7F
        sta     tok_n
@litb:  jsr     @wbyte
        ldy     dst_y
        sta     (ptr2),y
        iny
        sty     dst_y
        bne     @litn
        jsr     @page
        beq     @done
@litn:  dec     tok_n
        bne     @litb
        jmp     @token

@done:  rts

@page:  inc     ptr2+1          ; next output page; Z set when finished
        dec     pages_left
        lda     pages_left
        rts

@wbyte: lda     wlen            ; next wire byte; A=0/Z when exhausted
        ora     wlen+1
        beq     @wend
        lda     wlen
        bne     @wd
        dec     wlen+1
@wd:    dec     wlen
@wp:    lda     acia_stat,x
        and     #$08
        bne     @wg
        lda     kbd
        bpl     @wp
        cmp     #$9B
        beq     @wq
        sta     kbdstrb         ; keys are just tossed mid-photo
        jmp     @wp
@wg:    lda     acia_data,x
        rts
@wend:  lda     #$00
        rts
@wq:    jmp     quit

; ---------------------------------------------------------------
; Esc: restore the ACIA to 19200 8N1 for VSDRIVE, back to text
; page 1, clear the screen, return to BASIC.
; ---------------------------------------------------------------
quit:
        lda     acia_live
        beq     @screen
        ldx     slot_index
        lda     #$0B
        sta     acia_cmd,x
        lda     #$1F            ; 19200 8N1
        sta     acia_ctrl,x
        lda     acia_data,x
@screen:
        bit     kbdstrb
        sta     store80off
        sta     col80off
        bit     dhiresoff
        bit     lowscr
        bit     txtset
        jsr     home
        jmp     basic_warm

; ---------------------------------------------------------------
; Helpers.
; ---------------------------------------------------------------
read_key:
@wait:  lda     kbd
        bpl     @wait
        sta     kbdstrb
        rts

print_line:
        jsr     print
        jmp     crout

print:
        sta     ptr
        sty     ptr+1
        ldy     #$00
@loop:  lda     (ptr),y
        beq     @done
        ora     #$80
        jsr     cout
        iny
        bne     @loop
@done:  rts

        .segment "RODATA"

banner:
        .asciiz "A2MC RX V7.14.1 (KEYS+PHOTO+SND)"
s_slot:
        .asciiz "SSC IN SLOT "
s_confirm:
        .asciiz "RETURN=OK, 1-7=CHANGE, ESC=QUIT "
s_noslot:
        .asciiz "NO SSC FOUND. SLOT (1-7)? "
s_speed:
        .asciiz "SPEED: 1=19200 2=115200 ESC=QUIT "
s_slow:
        .asciiz "19200 8N1"
s_fast:
        .asciiz "115200 8N1"
s_wait:
        .asciiz "WAITING FOR STREAM. ESC QUITS."
