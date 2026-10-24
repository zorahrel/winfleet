# Prova: un movimento di mouse da zero pixel, cioe' un input vero senza spostare niente.
# Va lanciato nella sessione della console (vedi lancia-tocco.ps1): da ssh GetLastInputInfo non lo vede.
Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern void mouse_event(uint f, int dx, int dy, uint d, UIntPtr e);' -Name M -Namespace WFT
[WFT.M]::mouse_event(1, 0, 0, 0, [UIntPtr]::Zero)
