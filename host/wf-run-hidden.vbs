' Lancia un programma senza finestra e senza console.
'
' Serve ai processi persistenti di winfleet (il pinger dei monitor virtuali,
' l'agente, l'icona nella barra): devono girare per sempre e non devono lasciare
' niente sullo schermo di chi sta usando il PC.
'
' Perche' un VBScript e non un'opzione di powershell:
'   - "-WindowStyle Hidden" non impedisce al task di allocare una console, e su
'     un PC con Windows Terminal come terminale predefinito quella console e'
'     una finestra vera sul desktop;
'   - "conhost --headless" toglie la finestra ma BLOCCA il processo dentro:
'     wf-vdd restava vivo con il log fermo al primo giro e i monitor staccati.
' wscript.exe non alloca console affatto, quindi non c'e' ne' finestra da
' nascondere ne' console che si pianta.
'
' Il primo argomento e' il programma, gli altri i suoi parametri. Gli argomenti
' che contengono spazi vengono riquotati: senza, "-File C:\Program Files\..."
' arriverebbe spezzato in due.
Set sh = CreateObject("WScript.Shell")
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    a = WScript.Arguments(i)
    If InStr(a, " ") > 0 And Left(a, 1) <> """" Then a = """" & a & """"
    If i > 0 Then cmd = cmd & " "
    cmd = cmd & a
Next
' 0 = finestra nascosta, False = non aspettare la fine (il processo vive da solo).
sh.Run cmd, 0, False
