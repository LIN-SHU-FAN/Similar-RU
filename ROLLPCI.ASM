include inc\Standard.inc
include inc\File.inc
include inc\Struct.inc

.model small
.586

.data

Data1           db 31,0,31 dup(?)
BusData         db 0
DevData         db 0
FunData         db 0
PSP             dw 0

BDFMsg  db 10,13,"BDF = "
BusBuf  db 2 dup(0),':'
DevBuf  db 2 dup(0),'.'
FunBuf  db 1 dup(0),' ','$'

DevVenMsg db 10,13,"Device ID = "
DeviceData db 4 dup(0),'h  Vendor ID = '
VendorData db 4 dup(0),'h','$'


BusUpbound         dw 255
DevUpbound         dw 31
FunUpbound         dw 7

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

        call    BuildPCIList
        
        ret
Testa endp
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






end Testa
