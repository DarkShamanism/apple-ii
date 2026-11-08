; A2SC probe stub. The 6502 probe copies this to Z80 E300h (aux $6300 with
; $C07E=05h), plants JP E300h at Z80 0000h and starts the Z80 with $C07E=41h,
; the same sequence Premium CP/M 2.26B uses for its CCP and BIOS.
; Layout ABI used by src/softcard_probe.s:
;   E303h  JP loop          operand at E304h is replaced while the Z80 is held
;   E306h  DW phase2        address the 6502 copies into E304h
;   E380h  results          count(2), 0045h before and after the request,
;                           then 0400h, 0401h, 2000h, done
; Loop: INC HL (6) + LD (nn),HL (16) + JP (10) + JP (10) = 42 T-states.
        org 0xE300
        jp start
loopjp: jp loop
        dw phase2
start:  di
        ld sp,0xE400
        xor a
        ld i,a
        ld hl,0
        ld (0xE380),hl
loop:   inc hl
        ld (0xE380),hl
        jp loopjp
phase2: ld a,(0x0045)
        ld (0xE382),a
        ; Request 6502 service exactly like the 2.26B BIOS at FBB5h. The 6502
        ; writes its markers before and during this request.
        ld a,0x80
        ld i,a
        xor a
        ld i,a
        ld a,(0x0045)
        ld (0xE383),a
        ld a,(0x0400)
        ld (0xE384),a
        ld a,(0x0401)
        ld (0xE385),a
        ld a,(0x2000)
        ld (0xE386),a
        ld a,1
        ld (0xE387),a
park:   jr park
