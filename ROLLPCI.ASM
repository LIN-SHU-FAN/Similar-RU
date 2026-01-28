include inc\Standard.inc
include inc\File.inc
include inc\Struct.inc

.model small
.586

.data

PSP             dw 0


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

PAGE_SIZE   equ 10

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


.stack
.code

;--------------------------------------------------
Testa proc far
        push    ds
        xor     ax, ax
        push    ax

        mov     ax, @data
        mov     ds, ax
        mov     PSP, es


        call    InitPciDb
        call    BuildPCIList
        call    PageLoop
        

        ret
Testa endp

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




HexNibbleToAscii proc
        and     al, 0Fh
        cmp     al, 9
        jbe     Digit
        add     al, 7
Digit:
        add     al, '0'
        ret
HexNibbleToAscii endp

; AL = value, prints 2 hex chars
PrintHex8 proc
        push    ax
        push    bx

        mov     bl, al              ; backup original byte in BL

        ; high nibble
        mov     al, bl
        shr     al, 4
        call    HexNibbleToAscii
        mov     dl, al
        mov     ah, 02h
        int     21h

        ; low nibble
        mov     al, bl
        and     al, 0Fh
        call    HexNibbleToAscii
        mov     dl, al
        mov     ah, 02h
        int     21h

        pop     bx
        pop     ax
        ret
PrintHex8 endp


; AX = value, prints 4 hex chars
PrintHex16 proc
        push    ax

        mov     al, ah
        call    PrintHex8
        pop     ax
        call    PrintHex8
        ret
PrintHex16 endp




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

; --------------------------------------------
; PrintPage
; uses CurPage, PCICount, PCIList
; prints PAGE_SIZE entries per page
; --------------------------------------------
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
        mul     bx              ; DX:AX = CurPage*10 (AX enough)
        mov     si, ax          ; SI = start index

        ; for i=0..9:
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

        call    PrintOnePCIEntry

        inc     cx
        jmp     NextLine

Footer:
        ; (可選) 印一行提示
        mov     dx, offset StrCRLF
        mov     ah, 09h
        int     21h

        mov     dx, offset StrHint
        mov     ah, 09h
        int     21h

        mov     dx, offset StrCRLF
        mov     ah, 09h
        int     21h

        pop di
        pop si
        pop dx
        pop cx
        pop bx
        pop ax
        ret
PrintPage endp

GetKeyBIOS  proc
        mov ah, 00h
        int 16h            ; returns AL=ASCII, AH=scan
        ret
GetKeyBIOS  endp


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

Show:
        call PrintPage

KeyWait:
        call GetKeyBIOS 

        ; Q / q => exit
        cmp al, 'q'
        je  Exit
        cmp al, 'Q'
        je  Exit

        ; 直接看 scan code（不管 AL 是 00、E0、'9'、'3'）
        cmp ah, 49h            ; PageUp scan
        je  DoPgUp
        cmp ah, 51h            ; PageDown scan
        je  DoPgDn

        jmp KeyWait

DoPgUp:
        cmp CurPage, 0
        je  Show
        dec CurPage
        jmp Show

DoPgDn:
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

Exit:
        pop dx
        pop bx
        pop ax
        ret
PageLoop endp



PrintAllPCI proc
        xor     cx, cx              ; index = 0

NextEntry:
        cmp     cx, PCICount
        jae     Done

        mov     di, cx
        imul    di, SIZE PCI_ENTRY
        call    PrintOnePCIEntry

        inc     cx
        jmp     NextEntry

Done:
        ret
PrintAllPCI endp

; --------------------------------------------------
; PrintOnePCIEntry
; input: DI = offset of PCI_ENTRY
; --------------------------------------------------
PrintOnePCIEntry proc

        ; ---- NAME（暫用 Class code）----
        ; mov     al, PCIList[di].Class
        ; call    PrintHex8

        ; mov     dx, offset StrSpace
        ; mov     ah, 09h
        ; int     21h

        ; ---- NAME (RU-like from DB) ----
        mov     ax, PCIList[di].Vendor
        mov     bx, PCIList[di].Device
        call    LookupNameByVidDid
        jnc     PrintNameOk

        ; fallback: class-based
        call    GetDeviceName          ; DX=string

        mov     ah, 09h
        int     21h
        jmp     NameDone

PrintNameOk:
        mov     dx, offset NameBuf
        mov     ah, 09h
        int     21h

        mov     dx, offset StrCRLF
        mov     ah, 09h
        int     21h
        
NameDone:

        ; ---- PCI / PCIe ----
        cmp     PCIList[di].IsPCIe, 1
        jne     PrintPCI

        mov     dx, offset StrPCIe
        jmp     PrintBus

PrintPCI:
        mov     dx, offset StrPCI

PrintBus:
        mov     ah, 09h
        int     21h

        mov     dx, offset StrSpace
        mov     ah, 09h
        int     21h

        ; ---- Vendor:Device ----
        mov     ax, PCIList[di].Vendor
        call    PrintHex16

        mov     dx, offset StrColon
        mov     ah, 09h
        int     21h

        mov     ax, PCIList[di].Device
        call    PrintHex16

        mov     dx, offset StrSpace
        mov     ah, 09h
        int     21h

        ; ---- Bus:Dev.Fun ----
        mov     al, PCIList[di].Bus
        call    PrintHex8

        mov     dx, offset StrColon
        mov     ah, 09h
        int     21h

        mov     al, PCIList[di].Dev
        call    PrintHex8

        mov     dx, offset StrDot
        mov     ah, 09h
        int     21h

        mov     al, PCIList[di].Fun
        call    PrintHex8

        ; ---- newline ----
        mov     dx, offset StrCRLF
        mov     ah, 09h
        int     21h

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



; input: AX=Vendor, BX=Device
; output: CF=0 found (NameBuf ready), CF=1 not found
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


end Testa
