include inc\Standard.inc
include inc\File.inc
include inc\Struct.inc

.model small
.586

.data

PSP             dw 0

EcamBase        dd 0
EcamStartBus    db 0
EcamEndBus      db 0
Ecamfail        db 'MCFG not found', '$'

; 1 = FindRSDP failed
; 2 = RSDP checksum bad
; 3 = RSDT checksum bad
; 4 = XSDT checksum bad
; 5 = MCFG not found
; 6 = MCFG checksum bad
; 7 = No valid allocation entry
FailStep    db 0
        

RsdpSig db 'RSD PTR '

DbHandle        dw 0FFFFh
DbCount         dw 0
DbStrBase       dd 0              
DbFilename      db 'PCIDB.BIN',0

EntryBuf        db 8 dup(0)       ; VID(2) DID(2) OFF(4)
TmpCh           db 0
NameBuf         db 64 dup('$')



BusUpbound      dw 255
DevUpbound      dw 31
FunUpbound      dw 7

PCI_ENTRY struct
    Bus     db ?
    Dev     db ?
    Fun     db ?
    Vendor  dw ?
    Device  dw ?
    Class   db ?
    SubCls  db ?
    ProgIF  db ?
    IsPCIe  db ?     ; 0 = PCI, 1 = PCIe
PCI_ENTRY ends

MAX_PCI_ENTRY equ 256

PCIList   PCI_ENTRY MAX_PCI_ENTRY dup(<>)
PCICount  dw 0




CurPage   dw 0
CurRow    dw 0

PAGE_SIZE   equ 10

CurAttr db 07h     

StrPage     db 'Page ', '$'
StrSlash    db '/', '$'
StrHint     db 'PgUp/PgDn to scroll, Q to quit', '$'


TargetVID       dw 0
TargetDID       dw 0
MidTmp          dw 0

; ---- readable NAME strings ----
StrUnknown      db 'Unknown', '$'

StrBridge       db 'Bridge', '$'
StrHostBridge   db 'Host Bridge', '$'
StrPCIBridge    db 'PCI Bridge', '$'

StrStorage      db 'Storage', '$'
StrSATA         db 'SATA', '$'
StrNVMe         db 'NVMe', '$'
StrIDE          db 'IDE', '$'
StrRAID         db 'RAID', '$'

StrDisplay      db 'Display', '$'
StrVGA          db 'VGA', '$'
Str3D           db '3D', '$'

StrNetwork      db 'Network', '$'

StrUSB          db 'USB', '$'



BDFMsg          db 10,13,"BDF = "
BusBuf          db 2 dup(0),':'
DevBuf          db 2 dup(0),'.'
FunBuf          db 1 dup(0),' ','$'

DevVenMsg       db 10,13,"Device ID = "
DeviceData      db 4 dup(0),'h  Vendor ID = '
VendorData      db 4 dup(0),'h','$'


PrintBuf    db 64 dup('$')

StrPCI      db 'PCI ', '$'
StrPCIe     db 'PCIe', '$'
StrSpace    db ' ', '$'
StrColon    db ':', '$'
StrDot      db '.', '$'
StrCRLF     db 13,10,'$'


StrCfgTitle  db 'PCI Configuration Space (256B)', '$'
StrPCIECfgTitle  db 'PCIe Configuration Space (4096B)', '$'
StrEscHint   db 'ESC to back', '$'
StrPCIERollHint   db 'PgUp/PgDn to scroll', '$'

CurPCIEPage  db 0



.stack
.code


EXTERN  SetRealModeLimit(EmptyRoutine):FAR

;--------------------------------------------------
Testa proc far
        push    ds
        xor     ax, ax
        push    ax

        mov     ax, @data
        mov     ds, ax
        mov     PSP, es

        xor     ax, ax
        mov     es, ax
        mov     al, 1
        call    SetRealModeLimit ;es set -> big real mode

        call    GetEcamBase 
        jc      McfgFail

        ; mov     eax, EcamBase
        ; call    PrintHex32

        ; mov     dx , offset StrCRLF
        ; call    BiosPrintStringDollar

        ; mov     al, EcamStartBus
        ; call    PrintHex8

        ; mov     dx , offset StrCRLF
        ; call    BiosPrintStringDollar

        ; mov     al, EcamEndBus
        ; call    PrintHex8

        ; mov     dx , offset StrCRLF
        ; call    BiosPrintStringDollar

        call    InitPciDb
        call    BuildPCIList
        
        
        call    PageLoop
        jmp     ExitP

McfgFail:
        mov     al, FailStep
        call    PrintHex8
ExitP:
        xor     al, al
        call    SetRealModeLimit
        ret
Testa endp


EmptyRoutine    proc FAR
        ret
EmptyRoutine    endp

; SumCheck: AL = (sum of [EDI..EDI+ECX-1]) mod 256
; return ZF=1 if sum==0
SumCheck proc
    push edi
    push ecx
    xor eax, eax
@@L:
    test ecx, ecx
    jz   @@Done
    add  al, byte ptr es:[edi]
    inc  edi
    dec  ecx
    jmp  @@L
@@Done:
    pop ecx
    pop edi
    test al, al
    ret
SumCheck endp

; safer byte-compare "RSD PTR "
IsRSDP8 proc
    push esi
    lea  esi, RsdpSig
    mov  ecx, 8
@@C:
    mov al, byte ptr es:[edi]
    cmp al, byte ptr ds:[esi]
    jne @@Fail
    inc edi
    inc esi
    loop @@C
    xor ax, ax      ; ZF=1 trick? not needed
    pop esi
    ; indicate match by setting ZF=1 via cmp reg,reg
    xor ax, ax
    cmp ax, ax
    ret
@@Fail:
    pop esi
    or  ax, 1
    cmp ax, 0       ; ZF=0
    ret
IsRSDP8 endp

; Get EBDA base phys addr in EDI
GetEbdaBase proc
    ; EBDA segment stored at phys 0x40E
    mov edi, 040Eh
    mov ax, word ptr es:[edi]
    movzx edi, ax
    shl edi, 4
    ret
GetEbdaBase endp

; FindRSDP: return EDI = RSDP phys addr, CF=0 if found else CF=1
FindRSDP proc
    push ebx

    ; 1) scan EBDA first 1KB
    call GetEbdaBase
    mov ebx, edi            ; start
    add ebx, 400h           ; end = start+1KB
@@ScanEbda:
    cmp edi, ebx
    jae @@ScanHi
    push edi
    call IsRSDP8
    pop edi
    jnz @@Next16
    ; checksum first 20 bytes
    push edi
    mov ecx, 20
    call SumCheck
    pop edi
    jnz @@Next16            ; sum!=0
    clc
    pop ebx
    ret
@@Next16:
    add edi, 10h
    jmp @@ScanEbda

@@ScanHi:
    mov edi, 0E0000h
@@ScanHiLoop:
    cmp edi, 100000h
    jae @@NotFound
    push edi
    call IsRSDP8
    pop edi
    jnz @@Next16Hi
    push edi
    mov ecx, 20
    call SumCheck
    pop edi
    jnz @@Next16Hi
    clc
    pop ebx
    ret
@@Next16Hi:
    add edi, 10h
    jmp @@ScanHiLoop

@@NotFound:
    stc
    pop ebx
    ret
FindRSDP endp

; GetEcamBase: sets EcamBase/EcamStartBus/EcamEndBus, CF=0 success
GetEcamBase proc
    push ebx
    push esi
    mov FailStep, 0

    call FindRSDP
    jc   @@Fail_RSDP

;     ; EDI = RSDP
;     mov al, byte ptr es:[edi+15]     ; Revision
;     cmp al, 2
;     jb  @@UseRSDT

;     ; try XSDT if within 4GB and extended checksum ok
;     mov eax, dword ptr es:[edi+20]   ; Length
;     push edi
;     mov ecx, eax
;     call SumCheck                    ; extended checksum
;     pop edi
;     jnz @@UseRSDT

;     ; XSDT address at +24 (QWORD)
;     mov eax, dword ptr es:[edi+24]   ; low
;     mov edx, dword ptr es:[edi+28]   ; high
;     test edx, edx
;     jnz @@UseRSDT                    ; >4GB ignore
;     mov edi, eax
;     jmp @@ParseXSDT

@@UseRSDT:
    mov eax, dword ptr es:[edi+16]   ; RSDT addr
    mov edi, eax
    jmp @@ParseRSDT

@@ParseRSDT:
    cmp dword ptr es:[edi], 'TDSR'   ; "RSDT"
    jne @@Fail_notRSDT
    ; verify table checksum using Length
    mov eax, dword ptr es:[edi+4]    ; Length
    push edi
    mov ecx, eax
    call SumCheck
    pop edi
    jnz @@Fail_RSDTchecksum

    ; count = (Length-36)/4
    mov eax, dword ptr es:[edi+4]
    sub eax, 36
    shr eax, 2
    mov ebx, eax                     ; count
    lea esi, [edi+36]                ; esi => entry ptr
@@RLoop:
    test ebx, ebx
    jz @@Fail_RSDT_NoMCFG

    mov edi, dword ptr es:[esi]      ; edi => table addr

    ; --- debug: 印 signature 四個字 ---
;     mov  al, byte ptr es:[edi+0]
;     call BiosPutChar
;     mov  al, byte ptr es:[edi+1]
;     call BiosPutChar
;     mov  al, byte ptr es:[edi+2]
;     call BiosPutChar
;     mov  al, byte ptr es:[edi+3]
;     call BiosPutChar
;     mov  al, ' '
;     call BiosPutChar
    
    ; --- robust compare: "MCFG" ---
    cmp dword ptr es:[edi], 'GFCM'
    je  @@FoundMCFG_R
    add esi, 4
    dec ebx
    jmp @@RLoop


@@FoundMCFG_R:
    ; EAX still table addr in previous load? reload safely
    mov eax, dword ptr es:[esi]
    mov edi, eax
    jmp @@ParseMCFG

; @@ParseXSDT:
;     cmp dword ptr es:[edi], 'TDSX'   ; "XSDT"
;     jne @@UseRSDT                    ; 不是 XSDT 就回去走 RSDT
;     mov eax, dword ptr es:[edi+4]    ; Length
;     push edi
;     mov ecx, eax
;     call SumCheck
;     pop edi
;     jnz @@Fail_XSDTchecksum

;     ; count = (Length-36)/8
;     mov eax, dword ptr es:[edi+4]
;     sub eax, 36
;     shr eax, 3
;     mov ebx, eax
;     lea esi, [edi+36]
; @@XLoop:
;     test ebx, ebx
;     jz @@Fail_XSDT_NoMCFG
;     mov eax, dword ptr es:[esi]      ; low 32
;     mov edx, dword ptr es:[esi+4]    ; high 32
;     test edx, edx
;     jnz @@NextX
;     push edi
;     mov edi, eax
;     cmp dword ptr es:[edi], 'GFMC'
;     pop edi
;     je  @@FoundMCFG_X
; @@NextX:
;     add esi, 8
;     dec ebx
;     jmp @@XLoop

; @@FoundMCFG_X:
;     mov eax, dword ptr es:[esi]
;     mov edi, eax

@@ParseMCFG:
    ; verify MCFG checksum
    mov eax, dword ptr es:[edi+4]    ; Length
    push edi
    mov ecx, eax
    call SumCheck
    pop edi
    jnz @@Fail_MCFGchecksum

    ; allocations start at edi+44, each 16 bytes
    ;count = (Length - 44) / 16
    mov eax, dword ptr es:[edi+4]
    sub eax, 44
    xor edx, edx
    mov ecx, 16
    div ecx
    mov ebx, eax          ; count

    lea esi, [edi+44]
@@ALoop:
    test ebx, ebx
    jz @@Fail_MCFG_NoAlloc

    ; BaseAddress QWORD at [esi]
    mov eax, dword ptr es:[esi]      ; base low
    mov edx, dword ptr es:[esi+4]    ; base high
    test edx, edx
    jnz @@NextA                       ; >4GB skip

    ; SegmentGroup at [esi+8]
    mov cx, word ptr es:[esi+8]
    cmp cx, 0                           ; SegmentGroup != 0 skip
    jne @@NextA

    ; StartBus/EndBus
    mov dl, byte ptr es:[esi+10]
    mov dh, byte ptr es:[esi+11]

    ; pick this one
    mov dword ptr EcamBase, eax
    mov EcamStartBus, dl
    mov EcamEndBus, dh
    clc
    pop esi
    pop ebx
    ret

@@NextA:
    add esi, 16
    dec ebx
    jmp @@ALoop

; -----------------------------
; Unified fail exit
; -----------------------------
@@Fail:
    stc
    pop esi
    pop ebx
    ret

; -----------------------------
; Fail reason labels
; -----------------------------
@@Fail_RSDP:
    mov FailStep, 1
    jmp @@Fail

@@Fail_notRSDT:
    mov FailStep, 8
    jmp @@Fail

@@Fail_RSDTchecksum:
    mov FailStep, 2
    jmp @@Fail

@@Fail_RSDT_NoMCFG:
    mov FailStep, 3
    jmp @@Fail

; @@Fail_XSDTchecksum:
;     mov FailStep, 4
;     jmp @@Fail

; @@Fail_XSDT_NoMCFG:
;     mov FailStep, 5
;     jmp @@Fail

@@Fail_MCFGchecksum:
    mov FailStep, 6
    jmp @@Fail

@@Fail_MCFG_NoAlloc:
    mov FailStep, 7
    jmp @@Fail

GetEcamBase endp


InitPciDb proc
        mov     ah, 3Dh
        mov     al, 00h
        mov     dx, offset DbFilename
        int     21h
        jc      Fail
        mov     DbHandle, ax

        ; read 6-byte header -> NameBuf
        mov     bx, DbHandle
        mov     ah, 3Fh
        mov     cx, 6
        mov     dx, offset NameBuf
        int     21h
        cmp     ax, 6
        jne     FailClose

        cmp     byte ptr NameBuf+0, 'P'
        jne     FailClose
        cmp     byte ptr NameBuf+1, 'C'
        jne     FailClose
        cmp     byte ptr NameBuf+2, 'I'
        jne     FailClose
        cmp     byte ptr NameBuf+3, 'D'
        jne     FailClose

        mov     ax, word ptr NameBuf+4
        mov     DbCount, ax

        ; DbStrBase = 6 + DbCount*8
        movzx   eax, DbCount
        shl     eax, 3
        add     eax, 6
        mov     dword ptr DbStrBase, eax

        clc
        ret

FailClose:
        mov     bx, DbHandle
        mov     ah, 3Eh
        int     21h
Fail:
        mov     DbHandle, 0FFFFh
        stc
        ret
InitPciDb endp


; ==================================================
; Read Vendor/Device (offset 00h)
; output: EAX = DevID:VenID
; ==================================================
ReadVendorDevice proc
        ; xor     eax , eax
        mov     al , 00h
        call    ReadConfigDword
        ret
ReadVendorDevice endp

; ==================================================
; Read Header Type (offset 0Ch)
; output: AL = HeaderType (bit7 = multi-function)
; ==================================================
ReadHeaderType proc
        ; xor     eax , eax
        mov     al, 0Ch
        call    ReadConfigDword
        shr     eax, 16                        ; now AL = HeaderType
        ret
ReadHeaderType endp

; ==================================================
; Helper: Build CF8 address and read DWORD @ offset
; input: BX=Bus, CX=Dev, SI=Fun, AL=offset
; output: EAX = dword read from CFC
; ==================================================
ReadConfigDword proc

        xor     edx,edx
        mov     dl,al
        and     dl, 0FCh        ;ensure bit0,bit1 =0

        mov     eax, 80000000h                 ; enable
        or      eax, edx        ;offset

        movzx   edx, bx
        shl     edx, 16
        or      eax, edx

        movzx   edx, cx
        shl     edx, 11
        or      eax, edx

        movzx   edx, si
        shl     edx, 8
        or      eax, edx

        mov     dx, 0CF8h
        out     dx, eax
        mov     dx, 0CFCh
        in      eax, dx
        
        ret
ReadConfigDword endp


; ==================================================
; CheckPCIeCapability
; input : BX=Bus, CX=Dev, SI=Fun
; output: AL = 1 if PCIe, 0 if not
; ==================================================
CheckPCIeCapability proc
        ; -----------------------------
        ; Step 1: Read Status @ 06h
        ; -----------------------------
        mov     al, 04h            ; 04h → covers 04h–07h
        call    ReadConfigDword

        ; Status is at [31:16]
        shr     eax, 16
        test    ax, 0010h           ; Status bit4 ;cardbus ignore 
        jz      NotPCIe             ; no capability list

        ; -----------------------------
        ; Step 2: Read Cap Pointer @ 34h
        ; -----------------------------
        mov     al, 34h
        call    ReadConfigDword
        and     eax, 0FFh           ; AL = CapPtr
        cmp     al, 0
        je      NotPCIe

CapLoop:
        ; -----------------------------
        ; Step 3: Read Capability Header
        ; -----------------------------
        mov     dl, al          ; DL = CapPtr copy (byte offset)
        and     al, 0FCh
        call    ReadConfigDword

        and     dl, 3           ; DL = CapPtr % 4
        shl     dl, 3           ; dl = shift bits (0/8/16/24)

        push    cx
        mov     cl , dl
        shr     eax, cl

        pop     cx
        ; now AL = CapID, AH = NextPtr


        cmp     al, 10h             ; PCI Express Capability ID
        je      IsPCIe

        mov     al, ah              ; Next Capability Pointer
        cmp     al, 0
        jne     CapLoop

NotPCIe:
        xor     al, al              ; return 0
        jmp     Done

IsPCIe:
        mov     al, 1               ; return 1

Done:
        ret
CheckPCIeCapability endp


; ==================================================
; StoreOneEntry
; input:
;   BX,CX,SI are current BDF
;   EAX = DevID:VenID (from ReadVendorDevice)
; effect:
;   append one PCI_ENTRY into PCIList
; ==================================================
StoreOneEntry proc

        ; if full, just stop storing
        mov     dx, PCICount
        cmp     dx, MAX_PCI_ENTRY
        jae     StoreDone

        ; DI = index * SIZE PCI_ENTRY
        mov     di, dx
        imul     di, SIZE PCI_ENTRY

        ; Bus/Dev/Fun
        mov     PCIList[di].Bus, bl
        mov     PCIList[di].Dev, cl
        mov     dx , si
        mov     PCIList[di].Fun, dl

        ; Vendor/Device
        mov     PCIList[di].Vendor, ax          ; low 16 = vendor
        shr     eax, 16
        mov     PCIList[di].Device, ax          ; now AX=device

        ; Class/SubCls/ProgIF (offset 08h)
        ; xor     eax,eax
        mov      al, 08h
        call    ReadConfigDword                 ; EAX = Class/Sub/Prog/Rev

        mov     PCIList[di].ProgIF, ah          ; 09h
        shr     eax, 16
        mov     PCIList[di].SubCls, al          ; 0Ah
        mov     PCIList[di].Class, ah           ; 0Bh


        call    CheckPCIeCapability
        mov     PCIList[di].IsPCIe, al

        ; count++
        inc     PCICount

StoreDone:
        ret
StoreOneEntry endp


; ==================================================
; BuildPCIList
; - Scan PCI via CF8/CFC
; - Fill PCIList[] and PCICount
; ==================================================
BuildPCIList proc
        ; reset count
        mov     PCICount, 0

        mov     bx, 0                          ; Bus
Bus_Loop_BL:
        cmp     bx, BusUpbound
        ja      Done

        mov     cx, 0                          ; Device
Dev_Loop_CL:
        cmp     cx, DevUpbound
        ja      NextBus

        ; -------- function 0 first --------
        xor     si, si                         ; Fun = 0
        call    ReadVendorDevice               ; returns EAX = DevID:VenID
        cmp     ax, 0FFFFh                     ; if VenID = 0FFFF => not device
        je      NextDev                        ; no device at fun0

        ; store fun0
        call    StoreOneEntry

        ; check multi-function (Header Type bit7) at offset 0Ch
        call    ReadHeaderType                 ; returns AL = HeaderType
        test    al, 80h
        jz      NextDev                        ; single function

        ; -------- function 1~7 --------
        mov     si, 1
Fun_Loop_SI:
        cmp     si, FunUpbound
        ja      NextDev

        call    ReadVendorDevice
        cmp     ax, 0FFFFh
        je      NextFun

        call    StoreOneEntry

NextFun:
        inc     si
        jmp     Fun_Loop_SI

NextDev:
        inc     cx
        jmp     Dev_Loop_CL

NextBus:
        inc     bx
        jmp     Bus_Loop_BL

Done:
        ret
BuildPCIList endp


















;intput AL = hex num 
;output Al = ASCII
HexNibbleToAscii proc
        and     al, 0Fh
        cmp     al, 9
        jbe     Digit
        add     al, 7
Digit:
        add     al, '0'
        ret
HexNibbleToAscii endp

; BIOS version of PrintHex8 / PrintHex16
; --------------------------------------------------
; AL = value, prints 2 hex chars using BIOS
PrintHex8 proc
        push    ax
        push    bx

        mov     bl, al              ; backup original byte in BL

        ; high nibble
        mov     al, bl
        shr     al, 4
        call    HexNibbleToAscii
        call    BiosPutChar

        ; low nibble
        mov     al, bl
        and     al, 0Fh
        call    HexNibbleToAscii
        call    BiosPutChar

        pop     bx
        pop     ax
        ret
PrintHex8 endp


; AX = value, prints 4 hex chars using BIOS
PrintHex16 proc
        push    ax
        mov     al, ah
        call    PrintHex8
        pop     ax
        call    PrintHex8
        ret
PrintHex16 endp

; EAX = value, prints 8 hex chars using BIOS
PrintHex32 proc
        push    ax
        push    dx

        ; 先把 EAX 備份到 DX:AX (low16 in AX, high16 in DX)
        mov     dx, ax          ; DX = low16
        shr     eax, 16         ; AX = high16 (因為 shift 後低16就是原本高16)
        call    PrintHex16      ; 印 high16 (4 hex)

        mov     ax, dx          ; 還原 low16
        call    PrintHex16      ; 印 low16 (4 hex)

        pop     dx
        pop     ax
        ret
PrintHex32 endp



; Print one char in AL using BIOS teletype
; Uses: AH=0Eh, BH=page(0), BL=attr(07h)
BiosPutChar proc
        push ax
        push bx
        push cx
        push dx

        ; CR or LF 直接交給 teletype（負責換行/滾屏/游標）
        cmp  al, 0Dh
        je   @@TTY
        cmp  al, 0Ah
        je   @@TTY

        ; 1) 讀目前游標位置
        mov  ah, 03h
        mov  bh, 0
        int  10h            ; DH=row, DL=col

        ; 2) 在游標位置寫「字元+屬性」
        mov  ah, 09h
        mov  bh, 0
        mov  bl, CurAttr
        mov  cx, 1
        int  10h

        ; 3) 手動游標 +1（簡化：80x25）
        inc  dl
        cmp  dl, 80
        jb   @@SetCur
        xor  dl, dl
        inc  dh

        ; 超過第 24 列就滾一行（row=24 為最後一行）
        cmp  dh, 25
        jb   @@SetCur
        mov  ax, 0601h      ; scroll up 1 line
        mov  bh, CurAttr
        mov  cx, 0000h
        mov  dx, 184Fh
        int  10h
        mov  dh, 24
        mov  dl, 0

@@SetCur:
        mov  ah, 02h
        mov  bh, 0
        int  10h
        jmp  @@Done

@@TTY:
        mov  ah, 0Eh
        mov  bh, 0
        int  10h

@@Done:
        pop  dx
        pop  cx
        pop  bx
        pop  ax
        ret
BiosPutChar endp


; Print $-terminated string at DS:DX using BIOS teletype
BiosPrintStringDollar proc
        push    ax
        push    si
        mov     si, dx
@@L:
        lodsb
        cmp     al, '$'
        je      @@Done
        call    BiosPutChar
        jmp     @@L
@@Done:
        pop     si
        pop     ax
        ret
BiosPrintStringDollar endp




ClearScreen proc
        push ax
        push bx
        push cx
        push dx

        ; Scroll up whole screen (clear)
        mov  ax, 0600h      ; AH=06 scroll up, AL=0 clear
        mov  bh, 07h        ; attribute
        mov  cx, 0000h      ; upper-left (row0,col0)
        mov  dx, 184Fh      ; lower-right (row24,col79)
        int  10h

        ; Cursor to (0,0)
        mov  ah, 02h
        mov  bh, 0
        mov  dx, 0000h
        int  10h

        pop dx
        pop cx
        pop bx
        pop ax
        ret
ClearScreen endp


GetKeyBIOS  proc
        mov ah, 00h
        int 16h            ; returns AL=ASCII, AH=scan
        ret
GetKeyBIOS  endp


; ==================================================
; PrintOnePCIEntry (BIOS only)
; input: DI = offset of PCI_ENTRY in PCIList
; output: two lines per entry
; ==================================================
PrintOnePCIEntry proc

        ; ---- NAME (RU-like from DB) ----
        mov     ax, PCIList[di].Vendor
        mov     bx, PCIList[di].Device
        call    LookupNameByVidDid
        jnc     PrintNameOk

        ; fallback: class-based
        call    GetDeviceName          ; DX = $-terminated string
        call    BiosPrintStringDollar
        jmp     NameCRLF

PrintNameOk:
        mov     dx, offset NameBuf
        call    BiosPrintStringDollar

NameCRLF:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; ---- PCI / PCIe ----
        cmp     PCIList[di].IsPCIe, 1
        jne     PrintPCI

        mov     dx, offset StrPCIe
        jmp     PrintBus

PrintPCI:
        mov     dx, offset StrPCI

PrintBus:
        call    BiosPrintStringDollar

        mov     dx, offset StrSpace
        call    BiosPrintStringDollar

        ; ---- Vendor:Device ----
        mov     ax, PCIList[di].Vendor
        call    PrintHex16

        mov     dx, offset StrColon
        call    BiosPrintStringDollar

        mov     ax, PCIList[di].Device
        call    PrintHex16

        mov     dx, offset StrSpace
        call    BiosPrintStringDollar

        ; ---- Bus:Dev.Fun ----
        mov     al, PCIList[di].Bus
        call    PrintHex8

        mov     dx, offset StrColon
        call    BiosPrintStringDollar

        mov     al, PCIList[di].Dev
        call    PrintHex8

        mov     dx, offset StrDot
        call    BiosPrintStringDollar

        mov     al, PCIList[di].Fun
        call    PrintHex8

        ; ---- newline ----
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ret
PrintOnePCIEntry endp




; input: EAX = absolute file offset
SeekAbs32 proc
        push    ax
        push    bx
        push    cx
        push    dx

        mov     dx, ax          ; low16
        shr     eax, 16
        mov     cx, ax          ; high16

        mov     bx, DbHandle
        mov     ah, 42h
        mov     al, 00h
        int     21h

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
SeekAbs32 endp


DbReadCStringToNameBuf proc
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        mov     si, offset NameBuf
        mov     cx, 63               ; remaining chars

ReadLoop:
        ; read 1 byte -> TmpCh
        mov     bx, DbHandle
        mov     ah, 3Fh
        mov     dx, offset TmpCh
        push    cx                   ; keep remaining
        mov     cx, 1
        int     21h
        pop     cx
        cmp     ax, 1
        jne     Terminate

        mov     al, TmpCh
        cmp     al, 0
        je      Terminate

        mov     [si], al
        inc     si
        loop    ReadLoop

Terminate:
        mov     byte ptr [si], '$'

        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
DbReadCStringToNameBuf endp


; input: AX=Vendor, BX=Device
; output: CF=0 found (NameBuf ready), CF=1 not found
LookupNameByVidDid proc
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        cmp     DbHandle, 0FFFFh
        je      NotFound

        ; store targets in memory (avoid reg clobber)
        mov     TargetVID, ax
        mov     TargetDID, bx

        xor     si, si
        mov     di, DbCount
        dec     di
        js      NotFound

BS_Loop:
        cmp     si, di
        ja      NotFound

        ; mid = (low+high)/2
        mov     cx, si
        add     cx, di
        shr     cx, 1
        mov     MidTmp, cx

        ; entry_offset = 6 + mid*8
        movzx   eax, cx
        shl     eax, 3
        add     eax, 6
        call    SeekAbs32

        ; read entry 8 bytes -> EntryBuf
        mov     bx, DbHandle
        mov     ah, 3Fh
        mov     cx, 8
        mov     dx, offset EntryBuf
        int     21h
        cmp     ax, 8
        jne     NotFound

        ; compare VID
        mov     ax, word ptr EntryBuf+0
        mov     bp, TargetVID
        cmp     bp, ax
        jb      GoLeft
        ja      GoRight

        ; compare DID
        mov     ax, word ptr EntryBuf+2
        mov     bp, TargetDID
        cmp     bp, ax
        jb      GoLeft
        ja      GoRight

        ; FOUND: abs = DbStrBase + NameOff(dword)
        mov     eax, dword ptr EntryBuf+4
        add     eax, dword ptr DbStrBase
        call    SeekAbs32

        call    DbReadCStringToNameBuf
        clc
        jmp     Done

GoLeft:
        mov     cx, MidTmp
        mov     di, cx
        dec     di
        jmp     BS_Loop

GoRight:
        mov     cx, MidTmp
        mov     si, cx
        inc     si
        jmp     BS_Loop

NotFound:
        stc
Done:
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
LookupNameByVidDid endp




; --------------------------------------------------
; GetDeviceName
; input : DI = offset of PCI_ENTRY in PCIList
; output: DX = offset of $-terminated NAME string
; --------------------------------------------------
GetDeviceName proc
        ; default
        mov     dx, offset StrUnknown

        mov     al, PCIList[di].Class
        mov     ah, PCIList[di].SubCls
        mov     bl, PCIList[di].ProgIF

        ; -------------------------------
        ; Class 06h = Bridge
        ; -------------------------------
        cmp     al, 06h
        jne     CheckStorage

        ; SubCls 00h = Host bridge
        cmp     ah, 00h
        jne     BridgeOther
        mov     dx, offset StrHostBridge
        ret

BridgeOther:
        ; SubCls 04h = PCI-to-PCI bridge
        cmp     ah, 04h
        jne     BridgeGeneric
        mov     dx, offset StrPCIBridge
        ret

BridgeGeneric:
        mov     dx, offset StrBridge
        ret


CheckStorage:
        ; -------------------------------
        ; Class 01h = Mass Storage
        ; -------------------------------
        cmp     al, 01h
        jne     CheckDisplay

        ; SubCls 06h = SATA
        cmp     ah, 06h
        jne     StorageOther
        mov     dx, offset StrSATA
        ret

StorageOther:
        ; SubCls 08h = NVM (NVMe 常見在這類，ProgIF=02h)
        cmp     ah, 08h
        jne     StorageIDE
        ; 若你想更精準：ProgIF=02h => NVMe
        cmp     bl, 02h
        jne     StorageGeneric
        mov     dx, offset StrNVMe
        ret

StorageIDE:
        ; SubCls 01h = IDE
        cmp     ah, 01h
        jne     StorageRAID
        mov     dx, offset StrIDE
        ret

StorageRAID:
        ; SubCls 04h = RAID
        cmp     ah, 04h
        jne     StorageGeneric
        mov     dx, offset StrRAID
        ret

StorageGeneric:
        mov     dx, offset StrStorage
        ret


CheckDisplay:
        ; -------------------------------
        ; Class 03h = Display controller
        ; -------------------------------
        cmp     al, 03h
        jne     CheckNetwork

        ; SubCls 00h = VGA compatible controller
        cmp     ah, 00h
        jne     Display3D
        mov     dx, offset StrVGA
        ret

Display3D:
        ; SubCls 02h = 3D controller
        cmp     ah, 02h
        jne     DisplayGeneric
        mov     dx, offset Str3D
        ret

DisplayGeneric:
        mov     dx, offset StrDisplay
        ret


CheckNetwork:
        ; -------------------------------
        ; Class 02h = Network controller
        ; -------------------------------
        cmp     al, 02h
        jne     CheckUSB
        mov     dx, offset StrNetwork
        ret


CheckUSB:
        ; -------------------------------
        ; Class 0Ch = Serial Bus
        ; SubCls 03h = USB controller
        ; -------------------------------
        cmp     al, 0Ch
        jne     Done
        cmp     ah, 03h
        jne     Done
        mov     dx, offset StrUSB
        ret

Done:
        ret
GetDeviceName endp




; ==================================================
; PrintPage (BIOS only)
; uses CurPage, PCICount, PCIList
; prints PAGE_SIZE entries per page
; ==================================================
PrintPage proc
        push ax
        push bx
        push cx
        push dx
        push si
        push di

        call ClearScreen

        ; start = CurPage * PAGE_SIZE
        mov     ax, CurPage
        mov     bx, PAGE_SIZE
        mul     bx              ; DX:AX = CurPage*10
        mov     si, ax          ; SI = start index

        xor     cx, cx          ; i = 0
NextLine:
        cmp     cx, PAGE_SIZE
        jae     Footer

        ; idx = start + i
        mov     ax, si
        add     ax, cx

        ; if idx >= PCICount => stop page
        cmp     ax, PCICount
        jae     Footer

        ; DI = idx * SIZE PCI_ENTRY
        mov     bx, SIZE PCI_ENTRY
        mul     bx              ; AX = idx*size
        mov     di, ax

        ; if (cx == CurRow) CurAttr=1Fh else CurAttr=07h
        mov     CurAttr, 07h
        cmp     cx,CurRow
        jne     Ptpci
        mov     CurAttr, 1Fh
Ptpci:
        call    PrintOnePCIEntry

        mov     CurAttr, 07h
        inc     cx
        jmp     NextLine

Footer:
        ; hint
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        mov     dx, offset StrHint
        call    BiosPrintStringDollar

        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
PrintPage endp



; --------------------------------------------
; GetLastRowOnPage
; out: AX = LastRow (0..PAGE_SIZE-1, 依本頁實際筆數)
; uses: BX, DX
; --------------------------------------------
GetLastRowOnPage proc
        push bx
        push dx

        ; start = CurPage * PAGE_SIZE
        mov     ax, CurPage
        mov     bx, PAGE_SIZE
        mul     bx              ; DX:AX = start
        ; AX = start

        ; if start >= PCICount => LastRow = 0
        cmp     ax, PCICount
        jae     @@Zero

        ; remain = PCICount - start
        mov     dx, PCICount
        sub     dx, ax          ; DX = remain (1..)

        ; rows = min(remain, PAGE_SIZE)
        mov     ax, dx          ; AX = remain
        cmp     ax, PAGE_SIZE
        jbe     @@RowsOK
        mov     ax, PAGE_SIZE
@@RowsOK:
        ; LastRow = rows - 1
        dec     ax
        jmp     @@Done

@@Zero:
        xor     ax, ax          ; LastRow = 0

@@Done:
        pop     dx
        pop     bx
        ret
GetLastRowOnPage endp











; ==================================================
; ReadConfigByte
; input : BX=Bus, CX=Dev, SI=Fun, AL=byte offset (0..FF)
; output: AL = byte value
; ==================================================
ReadConfigByte proc
        push    bx
        push    cx
        push    dx

        mov     dl, al          ; DL = original byte offset (0..FF)
        and     al, 0FCh        ; dword-aligned offset

        push    dx              ; ★保存 original offset（因為 ReadConfigDword 會改 EDX/DL）
        call    ReadConfigDword ; EAX = dword
        pop     dx              ; ★取回原本的 DL

        mov     cl, dl
        and     cl, 3
        shl     cl, 3           ; shift = (offset&3)*8
        shr     eax, cl         ; target byte -> AL

        pop     dx
        pop     cx
        pop     bx
        ret
ReadConfigByte endp


; input: AL = 0..0F
PrintHex1 proc
        push    ax
        call    HexNibbleToAscii
        call    BiosPutChar
        pop     ax
        ret
PrintHex1 endp


; if it's PCI zf = 1
PCIorPCIE proc
        push    ax
        push    bx
        push    di

        ; idx = CurPage*PAGE_SIZE + CurRow
        mov     ax, CurPage
        mov     bx, PAGE_SIZE
        mul     bx              ; AX = CurPage*PAGE_SIZE
        add     ax, CurRow      ; AX = idx

        ; di = idx
        mov     di, ax
        imul    di, SIZE PCI_ENTRY

        ; ZF=1 => IsPCIe==0 => PCI
        mov     al, PCIList[di].IsPCIe
        test    al, al

        pop     di
        pop     bx
        pop     ax
        ret
PCIorPCIE endp


; ==================================================
; ShowConfigSpace
; - uses CurPage, CurRow, PCIList, PCICount
; - show 16x16 bytes (00..FF)
; - ESC to return
; ==================================================
ShowConfigSpace proc
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    di
        push    bp

        ; idx = CurPage*PAGE_SIZE + CurRow
        mov     ax, CurPage
        mov     bx, PAGE_SIZE
        mul     bx              ; AX = CurPage*PAGE_SIZE
        add     ax, CurRow      ; AX = idx

        ; if idx >= PCICount -> return
        cmp     ax, PCICount
        jae     @@Back

        ; DI = idx * SIZE PCI_ENTRY
        mov     bx, SIZE PCI_ENTRY
        mul     bx
        mov     di, ax

        ; load BDF into regs expected by ReadConfigDword/Byte
        movzx   bx, byte ptr PCIList[di].Bus
        movzx   cx, byte ptr PCIList[di].Dev
        movzx   si, byte ptr PCIList[di].Fun

        call    ClearScreen

        ; Title
        mov     dx, offset StrCfgTitle
        call    BiosPrintStringDollar
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; Header row: "  " + 0..F
        ; 印兩格空白（讓上方欄位對齊左側 row header + 空白）
        mov     al, ' '
        call    BiosPutChar
        call    BiosPutChar

        mov     di, 0
@@HdrCol:
        cmp     di, 16
        jae     @@HdrDone
        mov     al, ' '
        call    BiosPutChar
        mov     al, dl          ; (不用) 先清
        mov     ax, di
        mov     al, al          ; AL = di (low)
        call    PrintHex1       ; 印 0..F
        mov     al, ' '
        call    BiosPutChar
        inc     di
        jmp     @@HdrCol
@@HdrDone:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; 16 rows
        mov     bp, 0           ; row = 0..15
@@RowLoop:
        cmp     bp, 16
        jae     @@Footer

        ; left header: row digit (0..F) + space
        mov     ax, bp
        mov     al, al
        call    PrintHex1
        mov     al, ' '
        call    BiosPutChar

        ; 16 cols
        mov     di, 0           ; col = 0..15
@@ColLoop:
        cmp     di, 16
        jae     @@RowEnd

        ; offset = row*16 + col
        mov     ax, bp
        shl     ax, 4           ; row*16
        add     ax, di
        mov     al, al          ; AL = offset

        call    ReadConfigByte  ; AL = byte
        call    PrintHex8       ; prints 2 hex chars

        mov     al, ' '
        call    BiosPutChar

        inc     di
        jmp     @@ColLoop

@@RowEnd:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar
        inc     bp
        jmp     @@RowLoop

@@Footer:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar
        mov     dx, offset StrEscHint
        call    BiosPrintStringDollar
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; wait ESC
@@WaitEsc:
        call    GetKeyBIOS
        cmp     al, 1Bh         ; ESC
        jne     @@WaitEsc

@@Back:
        pop     bp
        pop     di
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
ShowConfigSpace endp


;input eax = offset , BDF->bx ,cx ,si
;output eax = 32bit(dword) Config space
ReadPCIEConfig proc
        movzx   edx,bx
        shl     edx,20
        add     eax,edx ;bus

        movzx   edx,cx
        shl     edx,15
        add     eax,edx ;dev

        movzx   edx,si
        shl     edx,12
        add     eax,edx ;fun

        mov     eax, dword ptr es:[eax]  ; 讀 offset 0 的 DWORD

        ret
ReadPCIEConfig endp


;intput eax = 32bit PCIE config space
Print4PCIEConfig proc
        push    edx
        mov     edx,eax ;edx = PCIE config space

        call    PrintHex8      ;print al 
        mov     al, ' '
        call    BiosPutChar

        mov     al , ah         
        call    PrintHex8      ;print al 
        mov     al, ' '
        call    BiosPutChar


        shr     eax,16
        call    PrintHex8      ;print al  
        mov     al, ' '
        call    BiosPutChar

        mov     al , ah 
        call    PrintHex8      ;print al 
        mov     al, ' '
        call    BiosPutChar


        mov     eax , edx
        pop     edx
        ret
Print4PCIEConfig endp

ShowPCIEConfigSpace proc
        push    ax
        push    bx
        push    cx
        push    dx
        push    si
        push    edi
        push    bp

        ; idx = CurPage*PAGE_SIZE + CurRow
        mov     ax, CurPage
        mov     bx, PAGE_SIZE
        mul     bx              ; AX = CurPage*PAGE_SIZE
        add     ax, CurRow      ; AX = idx

        ; if idx >= PCICount -> return
        cmp     ax, PCICount
        jae     @@Back

        ; DI = idx * SIZE PCI_ENTRY
        mov     bx, SIZE PCI_ENTRY
        mul     bx
        mov     di, ax

        ; load BDF into regs expected by ReadConfigDword/Byte
        movzx   bx, byte ptr PCIList[di].Bus
        movzx   cx, byte ptr PCIList[di].Dev
        movzx   si, byte ptr PCIList[di].Fun

        mov     CurPCIEPage,0
@@PrintScreen:
        call    ClearScreen

        ; Title
        mov     dx, offset StrPCIECfgTitle
        call    BiosPrintStringDollar
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; Header row: "  " + 0..F
        ; 印三格空白（讓上方欄位對齊左側 row header + 空白）
        mov     al, ' '
        call    BiosPutChar
        call    BiosPutChar
        call    BiosPutChar

        mov     di, 0
@@HdrCol:
        cmp     di, 16
        jae     @@HdrDone
        mov     al, ' '
        call    BiosPutChar
        mov     al, dl          ; (不用) 先清
        mov     ax, di
        mov     al, al          ; AL = di (low)
        call    PrintHex1       ; 印 0..F
        mov     al, ' '
        call    BiosPutChar
        inc     di
        jmp     @@HdrCol
@@HdrDone:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; 16 rows
        mov     bp, 0           ; bp->row = 0..15
@@RowLoop:
        cmp     bp, 16
        jae     @@Footer

        ; left header: row digit (0..F) + space

        ;page 
        movzx     ax, CurPCIEPage
        mov     al, al
        call    PrintHex1
        mov     al, ' '
        call    BiosPutChar

        ; row
        mov     ax, bp
        mov     al, al
        call    PrintHex1
        mov     al, ' '
        call    BiosPutChar

        ; 16 cols
        mov     edi, 0           ; col = 0..15
@@ColLoop:
        cmp     edi, 16          ;di -> col
        jae     @@RowEnd

        ; offset = page*256 + row*16 + col
        movzx   eax,CurPCIEPage
        shl     eax, 8           ; page*256

        movzx   edx,bp
        shl     edx, 4           ; row*16
        add     eax, edx

        add     eax,edi          ;eax = ECAM offset(0~11bit)


        call    ReadPCIEConfig  ;eax = 32bit config space memory

        call    Print4PCIEConfig 
        

        add     edi, 4
        jmp     @@ColLoop

@@RowEnd:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar
        inc     bp
        jmp     @@RowLoop

@@Footer:
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar
        mov     dx, offset StrEscHint
        call    BiosPrintStringDollar
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar


        mov     dx, offset StrPCIERollHint
        call    BiosPrintStringDollar
        mov     dx, offset StrCRLF
        call    BiosPrintStringDollar

        ; wait ESC
@@Waitkey:
        call    GetKeyBIOS
        
        cmp     al, 1Bh         ; ESC
        je      @@Back

        cmp     ah, 49h            ; PageUp
        je      @@DoPgUp

        cmp     ah, 51h            ; PageDown
        je      @@DoPgDn

        jmp     @@Waitkey

@@DoPgUp:
        cmp     CurPCIEPage,0
        je      @@Waitkey

        dec     CurPCIEPage
        jmp     @@PrintScreen

@@DoPgDn:
        cmp     CurPCIEPage,15
        je      @@Waitkey

        inc     CurPCIEPage
        jmp     @@PrintScreen

@@Back:
        pop     bp
        pop     edi
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret
ShowPCIEConfigSpace endp

; --------------------------------------------
; PageLoop
; PgUp/PgDn change CurPage
; Q quits
; --------------------------------------------
PageLoop proc
        push ax
        push bx
        push dx

        mov CurPage, 0
        mov CurRow, 0
        
Show:
        
        call PrintPage

KeyWait:
        call GetKeyBIOS        ; AL=ASCII, AH=scan

        ; Q / q => exit
        cmp al, 'q'
        je  Exit
        cmp al, 'Q'
        je  Exit

        ; scan code for PgUp/PgDn
        cmp ah, 49h            ; PageUp
        je  DoPgUp
        cmp ah, 51h            ; PageDown
        je  DoPgDn

        ;row up or down
        cmp ah, 48h            ; up
        je  DoUp
        cmp ah, 50h            ; Down
        je  DoDown

        cmp     al, 0Dh
        je      DoEnter

        jmp KeyWait

DoPgUp:
        mov CurRow, 0
        cmp CurPage, 0
        je  Show
        dec CurPage
        jmp Show

DoPgDn:
        mov CurRow, 0
        ; maxPage = (PCICount-1) / PAGE_SIZE
        mov ax, PCICount
        cmp ax, 0
        je  Show
        dec ax
        xor dx, dx
        mov bx, PAGE_SIZE
        div bx                 ; AX = maxPage

        cmp CurPage, ax
        jae Show
        inc CurPage
        jmp Show
DoUp:
        cmp CurRow, 0
        je  Show
        dec CurRow
        jmp Show
DoDown:
        call    GetLastRowOnPage    ; AX=LastRow
        cmp     CurRow, ax
        jae     Show                ; CurRow >= LastRow → 不動
        inc     CurRow
        jmp     Show

DoEnter:
        call    PCIorPCIE
        jz      IsPCIDev

        call    ShowPCIEConfigSpace
        jmp     Show
IsPCIDev:
        call    ShowConfigSpace
        jmp     Show
Exit:
        pop dx
        pop bx
        pop ax
        ret
PageLoop endp


end Testa
