;; Volkswagen CD Changer Emulator
;; For use on PIC16F627 at 4MHz/5VDC
;;
;; Copyright (c) 2002, Edward Schlunder <zilym@yahoo.com>
;;
;; Monsoon protocol information contributed by Andy Wilson <awilson@microsoft.com>
;; Monsoon debugged code contributed by Paul Stewart <stewart@parc.com>
;;
;; $Log: vwcdpic-1.4.asm,v $
;; Revision 1.1  2003/04/04 07:52:52  edwards
;; Initial import
;;
;; Revision 1.12  2002/12/02 00:13:44  edwards
;; Made the powered identify string display much slower now so that it won't
;; be so annoying.
;;
;; Moved the state jump table down to the end of program memory space so
;; that it is guaranteed to be page aligned.
;;
;; SendNEWLINE now sends character 13 followed by character 10 so that
;; Windows Hyperterminal will linefeed properly.
;;
;; Revision 1.11  2002/12/01 21:17:59  edwards
;; Added code to dump unknown command packets to the serial port.
;;
;; Revision 1.10  2002/12/01 20:50:39  edwards
;; My blind attempt at moving Paul Stewart's Monsoon code back into the
;; mainline firmware branch.
;;
;; Revision 1.9  2002/12/01 08:43:36  edwards
;; Formatting changes for MPLAB IDE 6.
;;
;; Revision 1.8  2002/12/01 08:25:53  edwards
;; Added project file for MPLAB IDE 6.
;;
;; v1.2
;; 	added first pass at a Monsoon state implementation, untested.
;;
;; v1.1b 
;; 	fixed SendSerialHex bugs
;;
;; v1.1
;;	removed all instances of ready-modify-write's to PORT regs
;; 	added CD[1..6] button recognition
;;	made display update send identification strings to serial
;;
;; v1.0
;;	initial release
	
	LIST P=16F627, R=DEC
	__CONFIG _BODEN_ON & _DATA_CP_OFF & _LVP_OFF & _MCLRE_OFF & _WDT_OFF & _PWRTE_ON & _CP_OFF & _INTRC_OSC_NOCLKOUT

#include <p16f627.inc>

;--------------------------------------------------------------------------
; Connections
;--------------------------------------------------------------------------
; PIC RA3 -> VW Pin 2 Clock  to Head Unit
; PIC RA2 -> VW Pin 1 Data   to Head Unit
; PIC RB0 <- VW Pin 4 Data from Head Unit
; Make sure PIC and VW Head Unit have common GND.
; 
; PIC RB6 -> PJRC RX
; PIC RB7 <- PJRC TX (not working at the moment)
; Make sure PIC and PJRC MP3 Player have common GND.
;--------------------------------------------------------------------------
SCLK			EQU		3
SRX				EQU		2
PWTX			EQU		0

SerialTX		EQU		6
SerialRX		EQU		7

HIGHTHRESHOLD	EQU		39		; timer counts greater than this
							; are HIGH bits. Otherwise LOW bit.

REFRESH_PERIOD	EQU		55		; refresh head unit every 55ms

VER_MAJOR		EQU		'1'
VER_MINOR		EQU		'4'

;--------------------------------------------------------------------------
; Variables
;--------------------------------------------------------------------------
ScratchPadRam   EQU     0x20
sendreg			EQU		ScratchPadRam+0
sendhexreg		EQU		ScratchPadRam+1
disc			EQU		ScratchPadRam+2
discload		EQU		ScratchPadRam+3	; next disc number to enable head
DISCMIN			EQU		0x19
DISCMAX			EQU		0x1F
track			EQU		ScratchPadRam+4

scanptr			EQU		ScratchPadRam+5
scanbyte		EQU		ScratchPadRam+6
buttonbyte1		EQU		ScratchPadRam+7
buttonbyte2		EQU		ScratchPadRam+8

sendbitcount	EQU		ScratchPadRam+9 ; Used in SendByte routine

intwsave		EQU		ScratchPadRam+10
intstatussave	EQU		ScratchPadRam+11
intfsrsave		EQU		ScratchPadRam+12

serialbit		EQU		ScratchPadRam+13
serialbyte		EQU		ScratchPadRam+14

capdone			EQU		0
mix				EQU		1
serialflag		EQU		2
progflags		EQU		ScratchPadRam+15
captime			EQU		ScratchPadRam+16 ; timer count of low pulse (temp)
capbit			EQU		ScratchPadRam+17 ; bits left to capture for this byte
capptr			EQU		ScratchPadRam+18 ; pointer to packet capture buffer loc
capbuffer		EQU		0xA0
capbufferend	EQU		0xF0

BIDIstate		EQU		ScratchPadRam+19
BIDIcount		EQU		ScratchPadRam+20

poweridentcount	EQU		ScratchPadRam+21

;--------------------------------------------------------------------------
; Note:	4MHz / 4 = 1MHz. 1/1MHz = 1us.
;       So each PIC instruction takes one microsecond long.
;--------------------------------------------------------------------------
; Program Code
;--------------------------------------------------------------------------
	ORG	0
	goto	Start

;--------------------------------------------------------------------------
; Interrupt Service Routine
; 
; Interrupt Sources:
;	RB0/INT Used for recieving head unit button commands
;	TMR0	Used for timing head unit button command pulse width
;	RB[4..7] on Change
;		Used for recieving 19.2Kbps serial data from PC/PJRC
;--------------------------------------------------------------------------
	ORG	4
	movwf	intwsave	; preserve w register
	swapf	STATUS, w	; preserve status register
	movwf	intstatussave

	movf	TMR0, w		; save a copy of current TMR0 count
	movwf	captime		; in case PWTXCaptureBit needs it

	movf	FSR, w		; preserve FSR register
	movwf	intfsrsave
	
PWTXCaptureISR
	btfss	INTCON, INTF; RB0/INT interrupt (PWTX Capture)?
	goto	SerialISR

	clrf	TMR0		; restart timer
	bcf		INTCON, INTF; clear interrupt flag

	btfsc	PORTB, PWTX
	goto	PWTXCaptureBit

PWTXStartTimer
	;; We have interrupted at beginning of low pulse (falling edge)
	;; Low pulse length must be timed to determine bit value

	bcf		INTCON, T0IF	; clear TMR0 overflow flag
	bsf		INTCON, T0IE	; enable TMR0 interrupt on overflow
	
	bsf		STATUS, RP0		; select data bank 1
	ERRORLEVEL -302
	bsf		OPTION_REG, INTEDG ; set interrupt on rising edge
	ERRORLEVEL +302
	bcf		STATUS, RP0		; go back to data bank 0

	goto	EndInterrupt

PWTXCaptureBit
	;; We have interrupted at beginning of high pulse (rising edge)
	;; High pulse length doesn't matter. We need to check out
	;; captured low pulse width if we are capturing data at the moment

	bsf		STATUS, RP0		; select data bank 1
	ERRORLEVEL -302
	bcf		OPTION_REG, INTEDG ; set interrupt on falling edge
	ERRORLEVEL +302
	bcf		STATUS, RP0		; go back to data bank 0

	btfss	INTCON, T0IE	; are we trying to capture data?
	goto	EndInterrupt

	bcf		INTCON, T0IE	; turn off capturing time for high pulse

	movf	capptr, w		; load capture pointer into indirect pointer
	movwf	FSR

	movlw	HIGHTHRESHOLD	; is the timer count larger than the
	subwf	captime, w		; HIGH bit threshold value?
	rrf		INDF, f			; save captured bit into capture buffer

	incfsz	capbit, f		; have we collected all 8 bits?
	goto	EndInterrupt

	incf	FSR, f			; increment capture pointer
	movlw	-8				; start capturing another 8 bits
	movwf	capbit
	
	movlw	capbufferend	; have we overflowed the 
	subwf	FSR, w			; capture buffer?
	btfss	STATUS, Z
	goto	ClearCapByte

	movlw	capbuffer		; yes, roll over to beginning
	movwf	FSR

ClearCapByte
	clrf	INDF			; starting new capture byte, initialize
							; byte to zeros for uneven captured bytes
	movf	FSR, w			; save capture pointer
	movwf	capptr

	goto	EndInterrupt

SerialISR
	btfss	INTCON, RBIF	; did a RB interrupt on change occur?
	goto	TMR0ISR

	bcf		INTCON, RBIF	; clear interrupt flag
	bsf		progflags, serialflag
	
	btfss	PORTB, SerialRX	; is this a start bit?
	goto	TMR0ISR	

	clrf	serialbyte
	movlw	-8				; capture 8 bits

	; [(3 or 4) + 18] microseconds to get here
	; 19200 bits per second. 5.2083333e-5 seconds per bit = 52us per bit.
	call	Wait56

SerialCaptureLoop
	bcf		STATUS, C	
	btfss	PORTB, SerialRX
	bsf		STATUS, C	

	rrf		serialbyte, f	; save current bit into capture byte
	call	Wait44
	addlw	1
	btfss	STATUS, Z
	goto	SerialCaptureLoop

	nop
	;btfsc	PORTB, SerialRX	; are we getting a valid stop bit?
	bsf		progflags, serialflag

TMR0ISR
	btfss	INTCON, T0IE	; is timer 0 overflow interrupt enabled?
	goto	EndInterrupt
	btfss	INTCON, T0IF	; if so, did a timer 0 overflow occur?
	goto	EndInterrupt

	bcf		INTCON, T0IE	; disable further timer 0 interrupts
	bsf		progflags, capdone ; set flag signifying packet capture done

	movlw	-8				; start capturing another 8 bits
	movwf	capbit
	incf	capptr, f		; make sure to include last capture byte
	movlw	capbufferend	; have we overflowed the 
	subwf	capptr, w		; capture buffer?
	btfss	STATUS, Z
	goto	ClearCapByte2

	movlw	capbuffer		; yes, roll over to beginning
	movwf	capptr

ClearCapByte2
	movf	capptr, w
	movwf	FSR	
	clrf	INDF			; clear capture byte (incomplete captures)

EndInterrupt
	movf	intfsrsave, w	; restore indirect pointer
	movwf	FSR
	swapf	intstatussave, w; restore STATUS register
	movwf	STATUS
	swapf	intwsave, f		; restore w register
	swapf	intwsave, w
	retfie

;--------------------------------------------------------------------------
; Main Program
;--------------------------------------------------------------------------
Start
	movlw	01000000b
	movwf	PORTA			; initialize port a data latches
	clrf	PORTB			; initialize port b data latches

	movlw	capbuffer		; initialize PWTX capture pointer and
	movwf	capptr			; indirect pointer to capture buffer
	movwf	scanptr

	movwf	FSR
	clrf	INDF			; make first cap byte clear for capturing

	movlw	-8				; read 8 bits of data per byte
	movwf	capbit		
	
	movlw   0x07            ; turn voltage comparators off so PORTA
	movwf   CMCON           ; can be used for regular i/o functions

	bsf		STATUS, RP0		; select data bank 1
	ERRORLEVEL -302
	bcf		TRISB, SerialTX	; set SerialTX pin as output
	bcf		TRISB, 1		; make unused RB pins outputs so they drive to GND
	bcf		TRISB, 2
	bcf		TRISB, 4
	bcf		TRISA, SCLK		; set SCLK pin as output
	bcf		TRISA, SRX		; set SRX pin as output
	bcf		TRISA, 6
	clrwdt					; clear WDT & prescaler (avoids possible reset)
	movlw	01000100b		; port b pull-ups enabled (incase SerialRX floating), 
	movwf	OPTION_REG		; interrupt on rising edge, timer 0 prescale 1:32
	ERRORLEVEL +302
	bcf		STATUS, RP0		; go back to data bank 0

	movlw	DISCMIN			; start with first disc number for head
	movwf	discload		; unit disc button enable packets.
	movlw	0xBE
	movwf	disc
	movlw	0xFE
	movwf	track
	
	movlw	1
	movwf	BIDIstate		; start in protocol state 1

	clrf	progflags
	clrf	poweridentcount

	bcf		INTCON, RBIF	; clear RB interrupt on change flag
	bcf		INTCON, INTF	; clear RB0/INT interrupt flag
	bsf		INTCON, INTE	; enable interrupt on RB0 rising edge
	bsf		INTCON, RBIE	; enable RB interrupt on change
	bsf		INTCON, GIE		; Global Interrupt Enable


	call	SendSerialIdentify
	call	SendSerialRING
	
	bsf		PIR1, TMR1IF	; force first display update packet

IdleLoop
	btfss	PIR1, TMR1IF	; has REFRESH_PERIOD time passed?
	goto	IdleLoopSkipSend

	call	SendPacket
	call	InitTIMER1		;  reinitialize timer so we can send the
							; next packet at the right time
	
	incf	poweridentcount, f	; only send the powered identify string
	btfsc	STATUS, Z		; once in a while
	call	SendSerialIdentify

IdleLoopSkipSend
	call	ScanButtons

;	btfss	progflags, serialflag
	goto	IdleLoop

;	bcf	progflags, serialflag
;
;	movf	serialbyte, w
;	call	SendSerialHex
;
;	goto	IdleLoop

;--------------------------------------------------------------------------
; InitTIMER1 - Reloads the registers associated with TIMER1 so that we
;	will get a flag for the next display update packet send within
;	REFRESH_PERIOD time.
;--------------------------------------------------------------------------
InitTIMER1
	bcf		T1CON, TMR1ON	; turn off timer while reloading wait period
	movlw	high (0xFFFF - (REFRESH_PERIOD * 1000))
	movwf	TMR1H
	movlw	low (0xFFFF - (REFRESH_PERIOD * 1000))
	movwf	TMR1L
	bcf		PIR1, TMR1IF	; clear old overflow (if any)
	movlw	00000001b		; 1:1 prescale, internal clock, tmr1 enabled.
	movwf	T1CON
	return

SendSerialIdentify
	movlw	'V'
	call	SendSerial
	movlw	'W'
	call	SendSerial
	movlw	'C'
	call	SendSerial
	movlw	'D'
	call	SendSerial
	movlw	'P'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'C'
	call	SendSerial
	movlw	VER_MAJOR
	call	SendSerial
	movlw	'.'
	call	SendSerial
	movlw	VER_MINOR
	call	SendSerial
	goto	SendNEWLINE

SendSerialRING
	movlw	'R'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'N'
	call	SendSerial
	movlw	'G'
	call	SendSerial
	goto	SendNEWLINE
	
		
;--------------------------------------------------------------------------
; ScanButtons - Looks in the button recieve packet buffer and tries
;	to match known button push packets.
;--------------------------------------------------------------------------
ScanButtons
	movf	scanptr, w		; load FSR register
	movwf	FSR
	
FirstByteLoop
	call	GetCaptureByte
	btfsc	STATUS, Z
	return
FirstByteTest
	movlw	0x95
	subwf	scanbyte, w
	btfss	STATUS, Z
	goto	FirstByteLoop
	
SecondByte
	call	GetCaptureByte
	btfsc	STATUS, Z
	return

	movlw	0x69
	subwf	scanbyte, w
	btfss	STATUS, Z
	goto	FirstByteTest

ThirdByte
	call	GetCaptureByte
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	movwf	buttonbyte1

FourthByte
	call	GetCaptureByte
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	movwf	buttonbyte2

FifthByte
	call	GetCaptureByte
	btfsc	STATUS, Z
	return

FifthByteTest
	movlw	0x80
	subwf	scanbyte, w
	btfss	STATUS, Z
	goto	FailedPacket
	
	; if execution reaches here, we have verified that 
	; bytes 1, 2, and 5 are valid for a button packet.

	call	ButtonDN
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonUP
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonSCAN
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonMIX
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonSEEKFW
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonSEEKBK
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD1
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD2
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD3
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD4
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD5
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	ButtonCD6
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	MonsoonEnable
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	MonsoonDisable
	btfsc	STATUS, Z
	goto	ScanButtonsEnd

	call	MonsoonInquiry
	btfsc	STATUS, Z
	goto	ScanButtonsEnd
	
	; if execution reaches here, we have verified that 
	; bytes 1, 2, and 5 are valid for a button packet, but
	; the packet recieved is not one that we understand,
	; so lets dump the data for the user to view.
DumpPacket
	movf	scanptr, w		; restart back at the beginning of the packet
	movwf	FSR

	call	GetCaptureByte	; send byte 1
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	call	SendSerialHex

	call	GetCaptureByte	; send byte 2
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	call	SendSerialHex

	call	GetCaptureByte	; send byte 3
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	call	SendSerialHex
	
	call	GetCaptureByte	; send byte 4
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	call	SendSerialHex

	call	GetCaptureByte	; send byte 5
	btfsc	STATUS, Z
	return
	movf	scanbyte, w
	call	SendSerialHex
		
ScanButtonsEnd
	movf	FSR, w			; save new scanptr
	movwf	scanptr
	return

FailedPacket
	movlw	2
	addwf	scanptr, f		; skip first two bytes next time
	return

;--------------------------------------------------------------------------
; Button Push Packets
;--------------------------------------------------------------------------
; 00         Power Up
; 95690CF280 Mix
; 95690AF480 Scan
; 956910EE80 Head Unit mode change. Emitted at power up, power down, and
;			 any mode change.
; 956934CA80 Seek Back Pressed
; 956936C880 Seek Forward Pressed
; 95693CC280 Dn
; 95693EC080 Up
; 956938C680 CD Change (third packet)
; 95694EB080 Seek Forward Released
; 95694EB080 Seek Back Released
; 95694EB080 CD Mode selected. Emitted at power up (if starting in CD 
;			 mode), change to CD mode.
; 956950AE80 CD Change (second packet)
; 9569609E80 CD 1
; 9569629C80 CD 2
; 9569649A80 CD 3
; 9569669880 CD 4
; 9569689680 CD 5
; 95696A9480 CD 6
;
; Monsoon:
; 95694EB080 enable (transition to State 2)
; 956938C680 disc loaded inquiry (transition to State 5)
; 956910EE80 (transition to State 1)
; xxxxB4xxxx ???? (incorrect?) disc loaded inquiry? (transition to State 5)
;--------------------------------------------------------------------------
MonsoonEnable
	movlw	0x4E
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xB0
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	call	SetState2

	movlw	'M'
	call	SendSerial
	movlw	'E'
	call	SendSerial
	movlw	'N'
	call	SendSerial
SendABLE
	movlw	'A'
	call	SendSerial
	movlw	'B'
	call	SendSerial
	movlw	'L'
	call	SendSerial
	movlw	'E'
	call	SendSerial
	goto	SendNEWLINE

MonsoonInquiry
	movlw	0x38
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xC6
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	call	SetState5

	movlw	'M'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'N'
	call	SendSerial
	movlw	'Q'
	call	SendSerial
	movlw	'U'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'R'
	call	SendSerial
	movlw	'Y'
	call	SendSerial
	goto	SendNEWLINE

MonsoonDisable
	movlw	0x10
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xEE
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	1				; goto State1
	movwf	BIDIstate

	movlw	DISCMIN			; get sendpacket to send the disc loading
	movwf	discload		; packets again (enables CD number buttons)

	movlw	'M'
	call	SendSerial
	movlw	'D'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'S'
	call	SendSerial
	goto	SendABLE

ButtonSEEKBK
	movlw	0x34
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xCA
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	incf	disc, f

	movlw	0xBF			; have we gone below CD 1?
	subwf	disc, w
	movlw	0xBE
	btfsc	STATUS, C
	movwf	disc			; yes, set back to CD 1

	movlw	'P'
	call	SendSerial
	movlw	'R'
	call	SendSerial
	movlw	'V'
	call	SendSerial
	goto	Send_LIST

ButtonSEEKFW
	movlw	0x36
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xC8
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	decf	disc, f

	movlw	0xB6			; have we gone above CD 9?
	subwf	disc, w
	movlw	0xB6
	btfss	STATUS, C
	movwf	disc			; yes, set back to CD 9

	movlw	'N'
	call	SendSerial
	movlw	'X'
	call	SendSerial
	movlw	'T'
	call	SendSerial
Send_LIST
	movlw	'_'
	call	SendSerial
	movlw	'L'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'S'
	call	SendSerial
	movlw	'T'
	call	SendSerial
SendNEWLINE
	movlw	13
	call	SendSerial
	movlw	10
	call	SendSerial

	bsf	STATUS, Z
	return

ButtonMIX
	movlw	0x0C
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xF2
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	1<<mix			; toggle mix display
	xorwf	progflags, f

	movlw	'R'
	call	SendSerial
	movlw	'A'
	call	SendSerial
	movlw	'N'
	call	SendSerial
	movlw	'D'
	call	SendSerial
	movlw	'O'
	call	SendSerial
	movlw	'M'
	call	SendSerial
	goto	SendNEWLINE

ButtonSCAN
	movlw	0x0A
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xF4
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	'P'				; this will make the PJRC play/pause
	call	SendSerial
	movlw	'L'
	call	SendSerial
	movlw	'A'
	call	SendSerial
	movlw	'Y'
	call	SendSerial
	goto	SendNEWLINE

ButtonUP
	movlw	0x3E
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xC0
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	decf	track, f

	movlw	0x0F			; skip past hexidecimal codes
	andwf	track, w
	addlw	-0x05
	movlw	-6
	btfsc	STATUS, Z		; are with at xF?
	addwf	track, f		; yes, subtract 6 and we'll be at x0 instead
	
	movlw	0x66			; have we gone beyond Track 99?
	subwf	track, w
	movlw	0x66
	btfss	STATUS, C
	movwf	track			; yes, set back to Track 99
	
	movlw	'N'
	call	SendSerial
	movlw	'E'
	call	SendSerial
	movlw	'X'
	call	SendSerial
	movlw	'T'
	call	SendSerial
	goto	SendNEWLINE

ButtonDN
	movlw	0x3C
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0xC2
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	incf	track, f

	movlw	0x0F			; skip past hexidecimal codes
	andwf	track, w
	movlw	6
	btfsc	STATUS, Z		; are with at xA?
	addwf	track, f		; yes, add 6 and we'll be at x9 instead

	movlw	0xFF			; have we gone below Track 1?
	subwf	track, w
	movlw	0xFE
	btfsc	STATUS, C
	movwf	track			; yes, set back to Track 1

	movlw	'P'
	call	SendSerial
	movlw	'R'
	call	SendSerial
	movlw	'E'
	call	SendSerial
	movlw	'V'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'O'
	call	SendSerial
	movlw	'U'
	call	SendSerial
	movlw	'S'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD1
	movlw	0x60
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x9E
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 1
	movwf	disc			; set CD 1

	call	SendLISTNo
	movlw	'1'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD2
	movlw	0x62
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x9C
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 2
	movwf	disc			; set CD 2

	call	SendLISTNo
	movlw	'2'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD3
	movlw	0x64
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x9A
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 3
	movwf	disc			; set CD 3

	call	SendLISTNo
	movlw	'3'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD4
	movlw	0x66
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x98
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 4
	movwf	disc			; set CD 4

	call	SendLISTNo
	movlw	'4'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD5
	movlw	0x68
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x96
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 5
	movwf	disc			; set CD 5

	call	SendLISTNo
	movlw	'5'
	call	SendSerial
	goto	SendNEWLINE

ButtonCD6
	movlw	0x6A
	subwf	buttonbyte1, w
	btfss	STATUS, Z
	return	

	movlw	0x94
	subwf	buttonbyte2, w
	btfss	STATUS, Z
	return	

	movlw	0xBF - 6
	movwf	disc			; set CD 6

	call	SendLISTNo
	movlw	'6'
	call	SendSerial
	goto	SendNEWLINE

SendLISTNo
	movlw	'L'
	call	SendSerial
	movlw	'I'
	call	SendSerial
	movlw	'S'
	call	SendSerial
	movlw	'T'
	call	SendSerial
	return

;--------------------------------------------------------------------------
; GetCaptureByte
; Returns: STATUS Z bit set - no more bytes to collect
; 	   STATUS Z bit clear - scanbyte contains next byte, FSR inc'd
;--------------------------------------------------------------------------
GetCaptureByte
	movf	FSR, w			; have we already caught up with capturer?
	subwf	capptr, w
	btfsc	STATUS, Z
	return

	movf	INDF, w			; get a byte from the capture buffer
	movwf	scanbyte

	incf	FSR, 1
	movlw	capbufferend	; have we overflowed the 
	subwf	FSR, w			; capture buffer?
	btfss	STATUS, Z
	return

	movlw	capbuffer		; yes, roll over to beginning
	movwf	FSR		
	bcf	STATUS, Z
	return			


;--------------------------------------------------------------------------
; msecWait - delays approximately one millisecond
;--------------------------------------------------------------------------
msecWait
	movlw	-249
msecWaitLoop
	addlw	1
	btfss	STATUS, Z
	goto	msecWaitLoop
	return

;-----------------------------------------------------
; Display Update Packets
;-----------------------------------------------------
BIDIstate1
	movlw	0x74
	call	SendByte

	call	SendDisplayBytes

	movlw	0x8F
	call	SendByte
	movlw	0x7C
	call	SendByte
	return

SetState2
	movlw	2
	movwf	BIDIstate
	movlw	-2
	movwf	BIDIcount
	return
; State 2:
;  packet = 2
;  cnt = 2 then transition to State 3
;  dbuf[0] = $94
;  dbuf[1] = $BE
;  dbuf[2] = $FE
;  dbuf[3] = $FF
;  dbuf[4] = $FF
;  dbuf[5] = $FF
;  dbuf[6] = $AE
;  dbuf[7] = $9C
BIDIstate2
	movlw	0x94
	call	SendByte

	call	SendDisplayBytes	; maybe this won't work, might need above bytes instead.

	movlw	0xAE
	call	SendByte
	movlw	0x9C
	call	SendByte

	incfsz	BIDIcount, f
	return
;	goto	SetState3

SetState3
	movlw	3
	movwf	BIDIstate
	movlw	-20
	movwf	BIDIcount
	return

; State 3:
;  packet = 3
;  cnt = 20 then transition to State 4
;  dbuf[0] = $34
;  dbuf[1] = $BE
;  dbuf[2] = $FE
;  dbuf[3] = $FF
;  dbuf[4] = $FF
;  dbuf[5] = $FF
;  dbuf[6] = $AE
;  dbuf[7] = $3C
BIDIstate3
	movlw	0x34
	call	SendByte

	call	SendDisplayBytes	; maybe this won't work, might need above bytes instead.

	movlw	0xAE
	call	SendByte
	movlw	0x3C
	call	SendByte

	incfsz	BIDIcount, f
	return
;	goto	SetState4

SetState4
	movlw	4
	movwf	BIDIstate
	return
; State 4:
;  packet = 4
;  cnt = -1
;  dbuf[0] = $34
;  dbuf[1] = $BE
;  dbuf[2] = $FE
;  dbuf[3] = $FF
;  dbuf[4] = $FF
;  dbuf[5] = $FF
;  dbuf[6] = $CF
;  dbuf[7] = $3C
BIDIstate4
	movlw	0x34
	call	SendByte

	call	SendDisplayBytes

	movlw	0xCF
	call	SendByte
	movlw	0x3C
	call	SendByte
	return

; State 5:
;  packet = 5
;  cnt = 2 then transition to State 4
;  dbuf[0] = $14
;  dbuf[1] = $2E
;  dbuf[2] = $FF
;  dbuf[3] = $FF
;  dbuf[4] = $FF
;  dbuf[5] = $FF
;  dbuf[6] = $FF
;  dbuf[7] = $1C
SetState5
	movlw	5
	movwf	BIDIstate
	movlw	-2
	movwf	BIDIcount
	return
BIDIstate5
	movlw	0x14
	call	SendByte
	movlw	0x2E 	; ??
	call	SendByte
	movlw	0xFF 	; 2 can do display update bytes here??
	call	SendByte
	movlw	0xFF	; 3
	call	SendByte
	movlw	0xFF 	; 4
	call	SendByte
	movlw	0xFF 	; 5
	call	SendByte
	movlw	0xFF 	; 6
	call	SendByte
	movlw	0x1C
	call	SendByte

	incfsz	BIDIcount, f
	return
	goto	SetState4


SendDisplayBytes
	movlw	DISCMAX		; are we trying to load CDs into head unit?
	subwf	discload, w
	movf	disc, w		; disc display value
	btfsc	STATUS, C
	goto	SendDisc
	movf	discload, w	; disc load
	incf	discload, f
SendDisc
	call	SendByte

	movf	track, w
	call	SendByte

	movlw	0xFF
	call	SendByte
	movlw	0xFF
	call	SendByte

	movlw	0xFB		; mode (scan/mix)
	btfss	progflags, mix
	iorlw	0x0F		; turn off mix light
	call	SendByte
	return

;--------------------------------------------------------------------------
; SendByte - sends a byte to head unit.
;            load byte to send to head unit into W register before calling
;--------------------------------------------------------------------------
SendByte
	movwf	sendreg

	movlw	-8			; send 8 bits of data
 	movwf	sendbitcount

	movf	PORTA, w
	bcf		INTCON, GIE	; disable interrupts, timing critical code

BitLoop
	iorlw	(1<<SCLK)	; SCLK high
	movwf	PORTA
        
	andlw   ~(1<<SRX)	; load the next bit onto SRX
	rlf		sendreg, 1	; load the next bit into the carry flag
	btfsc	STATUS, C
	iorlw	(1<<SRX)
	movwf	PORTA

	andlw	~(1<<SCLK)	; SCLK low
	movwf	PORTA

	incfsz	sendbitcount, f	; exit loop if we've transferred 8 bits already
	goto	BitLoop

	bsf		INTCON, GIE	; re-enable interrupts
	
	movlw	-84			; wait 335us for head unit to store sent byte
DelayLoop				
	addlw	1
	btfss	STATUS, Z
	goto	DelayLoop

	return

;--------------------------------------------------------------------------
; SendSerialHex - Sends byte provided in the W register using SendSerial.
;	The byte is converted to a two byte ASCII hexidecimal string
;--------------------------------------------------------------------------
SendSerialHex
	movwf	sendhexreg
	swapf	sendhexreg, w	; send high nibble first
	andlw	0x0F
	addlw	-10				; less than 10?
	btfsc	STATUS, C
	addlw	'A' - ('0' + 10); no, we're in the range [Ah..Fh]
	addlw	'0' + 10		; yes, range [0..9]
	call	SendSerial

	movf	sendhexreg, w	; now send low nibble
	andlw	0x0F
	addlw	-10
	btfsc	STATUS, C
	addlw	'A' - ('0' + 10)
	addlw	'0' + 10
	goto	SendSerial		; use SendSerial's return to return to caller
	
;--------------------------------------------------------------------------
; SendSerial - Sends 19.2Kbps 8 bit serial data using bit banging.
;	Place byte to transmit into W register before calling.
;	Interrupts will be temporarily disabled by this routine. On return,
;	interrupts will be enabled.
;--------------------------------------------------------------------------
SendSerial
	movwf	sendreg
	movlw	-9				; send 8 bits
	movwf	sendbitcount

	bcf		INTCON, GIE		; disable interrupts, timing critical code
	movf	PORTB, w

	; initially send start bit
LowBit
	iorlw	(1<<SerialTX)
	movwf	PORTB			; 1
	nop						; 1
	call	Wait42

BitCount
	incf	sendbitcount, f ; 1
	btfsc	STATUS, Z		; 1 2 exit loop if we've transferred 8 bits already
	goto    StopBit			; 2

	rrf		sendreg, 1		; 1 load next bit into carry flag
	btfss	STATUS, C       ; 1 2
	goto	LowBit          ; 2

	andlw	~(1<<SerialTX)  ; 1
	movwf	PORTB			; 1
	call	Wait42
	goto    BitCount        ; 2

StopBit
	goto    $+1				; 2
	andlw	~(1<<SerialTX)
	movwf	PORTB
	call	Wait44
	bsf		INTCON, GIE		; enable interrupts, timing critical code done
	return

;--------------------------------------------------------------------------
; WaitXX - Burns cpu cycles for timing purposes. XX = number of cycles
;--------------------------------------------------------------------------
Wait56
	goto    $+1	; 56
	goto    $+1	; 54
	goto    $+1	; 52
	goto    $+1	; 50
	goto    $+1	; 48
	goto    $+1	; 46
Wait44
	goto    $+1	; 44
Wait42
	goto    $+1	; 42
	goto    $+1	; 40
	goto    $+1	; 38
	goto    $+1	; 36
	goto    $+1	; 34
	goto    $+1	; 32
	goto    $+1	; 30
	goto    $+1	; 28
	goto    $+1	; 26
	goto    $+1	; 24
	goto    $+1	; 22
	goto    $+1	; 20
	goto    $+1	; 18
	goto    $+1	; 16
	goto    $+1	; 14
	goto    $+1	; 12
	goto    $+1	; 10
	goto    $+1	; 8
	goto    $+1	; 6
	return		; 4 (initial call used 2)


;--------------------------------------------------------------------------
; SendPacket - sends a display update packet to the head unit
;              currently hard coded to display "CD 1 Tr 1" on head unit
;--------------------------------------------------------------------------
	ORG	   	1014	;note: you must decrease this number if you add 
					;additional code below here.
SendPacket
; Monsoon requires use of 5 different states. This jumps to the correct
; state given the current value in the BIDIstate register.
	movlw	HIGH SendPacket
	movwf	PCLATH
	movf	BIDIstate, w
	addwf	PCL, f			
	nop						
	goto	BIDIstate1	
	goto	BIDIstate2
	goto	BIDIstate3
	goto	BIDIstate4
	goto	BIDIstate5

	END

