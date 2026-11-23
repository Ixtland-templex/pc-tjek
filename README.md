# PC-Tjek

Lille sikkerheds-, oprydnings- og optimeringsapp til Windows 11, skrevet i PowerShell og WPF.

- **Scanning (kun læsning):** Defender-fund, mistænkelige installationer, autostart, planlagte opgaver, tjenester, netværk, nye usignerede filer og browserudvidelser
- **Hændelsesforløb:** rekonstruerer, hvad en mistænkelig installer gjorde
- **Opstart:** til/fra som i Jobliste
- **Oprydning:** midlertidige filer, caches og papirkurv
- **Filer:** dubletter, gamle installere og store filer (sletter til papirkurven)
- **Opdateringer:** opdaterer programmer via winget
- **Ydelse og helbred:** disk-SMART, strømplan, spiltilstand og opstartstid
- **Selvopdatering:** tjekker `version.json` i dette repo og verificerer SHA256 før installation

## Installation
1. Download repoet (Code → Download ZIP), og pak det ud.
2. Dobbeltklik på `Installer PC-Tjek.cmd`, og godkend én gang.
3. Start fra ikonet på skrivebordet.

## Udgiv en ny version
```powershell
.\Udgiv-Version.ps1 -Version 2.2 -Notes 'Hvad er nyt', 'Hvad er rettet'
```
Commit og push derefter. Installerede apps viser en opdateringsboks ved næste start.
