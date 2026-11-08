; CP/M 2.2 helper. Run A2Z for local diagnostics; A2Z R for RDR:/PUN: service.
; CP/M owns the Premium IIe hardware mapping and processor handoff.
; Protocol: ':' + hex(command,length,payload,xor) + CR. All characters are 7 bit.
; Packets are staged and checked before writes. Modules use 0x4000..0x4FFF.
        org 0x0100
        ld a,(7)
        cp 0x050
        jp c,small_tpa
        ld sp,0x03f00
        xor a
        ld (ready),a
        ld hl,0
        ld (loaded),hl
        ld a,(0x080)
        or a
        jr z,local_test
        ld hl,0x081
skip_space:
        ld a,(hl)
        inc hl
        cp 32
        jr z,skip_space
        and 0x0df
        cp 82
        jp z,receive
local_test:
        call ram_test
        ld de,failed
        jr nz,local_print
        ld de,passed
local_print:
        ld c,9
        call 5
        jp 0
small_tpa:
        ld de,small_message
        jr local_print
receive:
        call input
        cp 58
        jr nz,receive
        call gethex
        jr c,receive
        ld (command),a
        ld (check),a
        call gethex
        jr c,receive
        cp 35
        jr nc,receive
        ld (length),a
        ld b,a
        ld a,(check)
        xor b
        ld (check),a
        ld a,b
        or a
        ld hl,packet
        jr z,read_checksum
read_payload:
        call gethex
        jr c,receive
        ld (hl),a
        inc hl
        ld e,a
        ld a,(check)
        xor e
        ld (check),a
        djnz read_payload
read_checksum:
        call gethex
        jr c,receive
        ld e,a
        ld a,(check)
        cp e
        jp nz,reject
        call input
        cp 13
        jp nz,reject
        ld a,(command)
        cp 87
        jp z,write_module
        cp 67
        jp z,commit_module
        cp 82
        jp z,read_module
        ld a,(length)
        or a
        jp nz,reject
        ld a,(command)
        cp 72
        jr z,hello
        cp 84
        jr z,diagnose
        cp 71
        jp z,run_module
        cp 81
        jr z,quit
        jp reject
hello:
        ld hl,signature
        ld b,4
        jp reply_ok
diagnose:
        call ram_test
        jp nz,reject
        ld c,12
        call 5
        ld a,l
        ld (packet),a
        ld a,(3)
        ld (packet+1),a
        ld hl,(6)
        ld (packet+2),hl
        ld a,1
        ld (packet+4),a
        ld hl,packet
        ld b,5
        jp reply_ok
quit:
        ld b,0
        ld a,6
        call reply
        jp 0
write_module:
        ; A new block at offset zero invalidates the previous executable.
        xor a
        ld (ready),a
        ld a,(length)
        cp 3
        jp c,reject
        sub 2
        ld b,a
        ld hl,(packet)
        ld a,h
        or l
        jr nz,write_contiguous
        ld (loaded),hl
write_contiguous:
        ld de,(loaded)
        or a
        sbc hl,de
        jp nz,reject
        ld hl,(loaded)
        ld e,b
        ld d,0
        add hl,de
        ld de,0x01001
        push hl
        or a
        sbc hl,de
        pop hl
        jp nc,reject
        ld de,(loaded)
        ld (loaded),hl
        ld hl,0x04000
        add hl,de
        ex de,hl
        ld hl,packet+2
        ld c,b
        ld b,0
        ldir
        jp acknowledge
commit_module:
        xor a
        ld (ready),a
        ld a,(length)
        cp 4
        jp nz,reject
        ld hl,(loaded)
        ld a,h
        or l
        jp z,reject
        ld de,(packet)
        or a
        sbc hl,de
        jp nz,reject
        ld bc,(loaded)
        ld hl,0x04000
        ld de,0
sum_loop:
        ld a,(hl)
        add a,e
        ld e,a
        jr nc,sum_next
        inc d
sum_next:
        inc hl
        dec bc
        ld a,b
        or c
        jr nz,sum_loop
        ld hl,(packet+2)
        or a
        sbc hl,de
        jp nz,reject
        ld a,1
        ld (ready),a
        jp acknowledge
read_module:
        ld a,(length)
        cp 3
        jp nz,reject
        ld a,(packet+2)
        or a
        jp z,reject
        cp 33
        jp nc,reject
        ld b,a
        ld e,a
        ld d,0
        ld hl,(packet)
        add hl,de
        jp c,reject
        ld de,(loaded)
        or a
        sbc hl,de
        jr z,read_valid
        jp nc,reject
read_valid:
        ld hl,(packet)
        ld de,0x04000
        add hl,de
        jp reply_ok
run_module:
        ld a,(ready)
        or a
        jp z,reject
        ; User module must preserve SP and return via RET; HL is its result.
        call 0x04000
        ld (packet),hl
        ld hl,packet
        ld b,2
        jp reply_ok
acknowledge:
        ld b,0
reply_ok:
        ld a,6
        call reply
        jp receive
reject:
        xor a
        ld (ready),a
        ld b,0
        ld a,0x015
        call reply
        jp receive
reply:
        ld (check),a
        push af
        ld a,58
        call output
        pop af
        call puthex
        ld a,b
        call puthex
        ld a,(check)
        xor b
        ld (check),a
        ld a,b
        or a
        jr z,reply_checksum
reply_bytes:
        ld a,(hl)
        call puthex
        ld a,(check)
        xor (hl)
        ld (check),a
        inc hl
        djnz reply_bytes
reply_checksum:
        ld a,(check)
        call puthex
        ld a,13
        call output
        ld a,10
        jp output
; BDOS can clobber registers. Preserve everything except input A.
input:
        push bc
        push de
        push hl
        ld c,3
        call 5
        pop hl
        pop de
        pop bc
        ret
output:
        push af
        push bc
        push de
        push hl
        ld e,a
        ld c,4
        call 5
        pop hl
        pop de
        pop bc
        pop af
        ret
gethex:
        call nibble
        ret c
        rlca
        rlca
        rlca
        rlca
        push af
        call nibble
        jr c,bad_nibble
        ld (low_nibble),a
        pop af
        push hl
        ld hl,low_nibble
        or (hl)
        pop hl
        ret
bad_nibble:
        pop af
        scf
        ret
nibble:
        call input
        sub 48
        ret c
        cp 10
        jr c,nibble_ok
        sub 7
        cp 10
        jr c,nibble_bad
        cp 16
        jr nc,nibble_bad
nibble_ok:
        or a
        ret
nibble_bad:
        scf
        ret
puthex:
        push af
        rrca
        rrca
        rrca
        rrca
        call put_nibble
        pop af
put_nibble:
        and 15
        add a,48
        cp 57+1
        jr c,put_digit
        add a,7
put_digit:
        jp output
ram_test:
        ; Only test this program's private 256-byte array, twice.
        ld d,0x055
ram_pass:
        ld ix,scratch
        ld b,0
ram_fill:
        ld a,b
        xor d
        ld (ix+0),a
        inc ix
        djnz ram_fill
        ld ix,scratch
        ld b,0
ram_verify:
        ld a,b
        xor d
        cp (ix+0)
        ret nz
        inc ix
        djnz ram_verify
        ld a,d
        cp 0x0aa
        ret z
        ld d,0x0aa
        jr ram_pass
signature: db 65,50,90,49
passed: db 65,50,90,58,32,90,56,48,32,105,110,100,101,120,101,100,32,82,65,77,32,116,101,115,116,32,80,65,83,83,59,32,66,68,79,83,32,99,111,110,115,111,108,101,32,114,101,116,117,114,110,46,13,10,36
failed: db 65,50,90,58,32,112,114,105,118,97,116,101,32,115,99,114,97,116,99,104,32,82,65,77,32,116,101,115,116,32,70,65,73,76,69,68,46,13,10,36
small_message: db 65,50,90,32,110,101,101,100,115,32,84,80,65,32,98,101,108,111,119,32,66,68,79,83,32,116,111,32,101,120,116,101,110,100,32,98,101,121,111,110,100,32,48,120,52,70,70,70,46,13,10,36
command: db 0
length: db 0
check: db 0
low_nibble: db 0
ready: db 0
loaded: dw 0
packet: ds 34
scratch: ds 256
