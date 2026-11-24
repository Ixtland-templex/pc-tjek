import hashlib, json, re, datetime
R='/home/claude/pc-tjek/'
rd=lambda f: open(R+f,encoding='utf-8-sig').read().replace('\r\n','\n')
ver='2.47'
BRAND='Opticon'   # skift navnet her
head=re.sub(r"\$AppVersion = '[\d.]+'", f"$AppVersion = '{ver}'", rd('head.ps1.part'))
app=head+rd('modes.ps1.part')+rd('engine.ps1.part')+rd('gui.ps1.part')+rd('logic.ps1.part')
v=rd('vagt.ps1.part'); assert '#@@MODES@@' in v
vagt=v.replace('#@@MODES@@', rd('modes.ps1.part'))
PROTECT=[r"PC-Tjek(?=-App|-Start|-Vagt\.ps1|\.ico|-rapport|-data|\\)", r"(?<=\\)PC-Tjek", r"(?<=\*)PC-Tjek",
 r"(?<=TaskName ')PC-Tjek", r"(?<=TaskName -eq ')PC-Tjek", r"(?<=ProgramData ')PC-Tjek", r"(?<=LOCALAPPDATA ')PC-Tjek",
 r"PC-Tjek(?= Vagt \(denne)", r"PC-Tjek(?= \(denne app)", r"(?<=opgave \")PC-Tjek", r"(?<=opgave ')PC-Tjek"]
def brand(t):
    for p in PROTECT: t=re.sub(p,'\x00PCT\x00',t)
    t=t.replace('PC-Tjek',BRAND)
    return t.replace('\x00PCT\x00','PC-Tjek')
app=brand(app); vagt=brand(vagt)
BAD_QUOTES=re.compile('[\u2018\u2019\u201a\u201b\u201c\u201d\u201e]')
for nm,t in (('app',app),('vagt',vagt),('start',rd('PC-Tjek-Start.ps1'))):
    for i,l in enumerate(t.split('\n'),1):
        if BAD_QUOTES.search(l): raise SystemExit(f'STOP: krøllet anførselstegn i {nm} linje {i}: {l.strip()[:120]}')
        if re.search(r'"[^"]*\$(?!env|script|global|using|local|private)[A-Za-z_][A-Za-z0-9_]*:(?![A-Za-z_])', l): raise SystemExit(f'STOP: "$navn:" i en tekst (skriv ${{navn}}:) i {nm} linje {i}: {l.strip()[:120]}')
def w(f,t): open(R+f,'wb').write(b'\xef\xbb\xbf'+t.replace('\n','\r\n').encode('utf-8'))
w('PC-Tjek-App.ps1',app); w('PC-Tjek-Vagt.ps1',vagt)
files=[]
for f in ['PC-Tjek-App.ps1','PC-Tjek-Start.ps1','PC-Tjek-Vagt.ps1','Uninstall-PCTjek.ps1','PC-Tjek.ico']:
    files.append({'name':f,'sha256':hashlib.sha256(open(R+f,'rb').read()).hexdigest().upper()})
notes=["Grafiktesten sender målinger med et fast ur, så målingen i din skærms opløsning ikke går tabt, og logger hvad testsiden laver",
 "Knappen Scan pc'en er flyttet ind på Overblik, hvor resultatet vises",
 "Grafiktesten måler nu direkte, hvor lang tid grafikkortet bruger pr. billede (FPS uden V-Sync). Mere stabilt, og virker også i din skærms opløsning",
 "Grafik-feltet viser FPS i din skærms opløsning (fx 2560×1440) som det store tal, og 1080p til sammenligning",
 "Grafiktal fra før 2.45 sammenlignes ikke med de nye (de var låst til skærmens Hz), og scoren er justeret til den nye måling",
 "Rettet: filer i Opticons låste mappe (C:\\ProgramData\\PC-Tjek) kunne ende helt uden adgang efter en genstart. Det ramte bl.a. MalwareBazaar-nøglen og genstarten efter opdatering. De repareres automatisk nu",
 "Benchmark tester også grafikken i din skærms egen opløsning (fx 2560×1440 eller 1920×1200), ud over 1080p til sammenligning",
 "Rettet: MalwareBazaar-nøglen blev ikke husket efter genstart (gemmes nu på en ny måde og tjekkes med det samme)",
 "Rettet: appen genstartede ikke selv efter en opdatering",
 "Baggrundsopgaver afleverer nu deres resultat præcis som før (rettelse til grafiktesten)",
 "Sårbare drivere: bruger nu Windows' egen beskyttelse (Microsofts blokeringsliste + Hukommelsesintegritet) i stedet for en scanning, som antivirus forvekslede med et angrebsværktøj",
 "Rettet: MalwareBazaar-nøglen kunne ikke testes (svaret blev læst forkert)",
 "Grafiktesten tæller nu målingerne pr. trin, så de ikke kan falde udenfor, og logger hvad der skete",
 "Endnu venligere for antivirus: disktesten bruger almindelig hukommelse, downloads sker med Windows' standardværktøj, og C#-hjælpere oversættes kun én gang pr. version",
 "Venligere for antivirus (fx Bitdefender): ingen ekstra PowerShell-processer, ingen kodede kommandoer og ingen skjulte omveje ved start",
 "Baggrundsopgaver kører nu inde i selve appen, så de er hurtigere at starte",
 "Eksisterende genveje og planlagte opgaver flyttes automatisk over på den nye startmåde",
 "Ny (valgfri): 🦠 Ekstra virustjek med MalwareBazaar – over 1 million kendte malware-filer. Indsæt din egen gratis nøgle under Sikkerhedstjek (guide inde i appen)",
 "Med nøgle: nye usignerede filer tjekkes ved hver scanning, og du kan tjekke en enkelt fil. Kun fingeraftrykket sendes, aldrig filen",
 "Ny: 🎮 Mål i mit spil (under Benchmark) – rigtig FPS, 1 % low og hak i dit eget spil med Intel PresentMon, og om det er grafikkort, processor eller et FPS-loft, der bremser",
 "Spilmålinger gemmes, så du kan se om en ændring hjalp (Mod sidst)",
 "Sikkerhedstjek: 3 ekstra Defender-regler (ASR), som Microsoft anbefaler alle at slå til",
 "Ydelse og helbred: tjekker om Game Bar optager i baggrunden, og kan slå det fra med ét klik",
 "Ny: 🔐 Sikkerhedstjek – er Windows' beskyttelser slået til? Røde og gule punkter med en forklaring, og knappen Ret det for mig, hvor det er sikkert",
 "Disk-helbred: fejl der ikke kunne rettes, temperatur mod diskens maks., og hvor længe den har været tændt. Overblik advarer, hvis disken er ved at gå i stykker",
 "Grafiktest giver nu rigtige FPS uden skærmens Hz-loft (testversion 3)",
 "Rettet: grafikdelen af benchmark og opløsningstest gav ingen målinger",
 "Ny: Hvad betyder dine tal? – advarer om varmetab, RAM uden XMP, langsom disk, forkert grafikkort m.m. og siger hvad du kan gøre",
 "Optimering ryddet op: tydelige live-tal, ekstra lister kun under Vis alt",
 "Ny: ✅ Hjalp det? – én historik over dine ændringer med måling før og efter",
 "Opstart måles ved de næste opstarter, oprydning som ledig plads, GPU-profiler i samme test",
 "Knap: Jeg har ændret noget – kører den store test og sammenligner med testen før",
 "Delvise benchmarks får ingen samlet score",
 "Kun bekræftede GPU-indstillinger indgår i anbefalinger",
 "Opdateringer skifter og ruller hele pakken samlet",
 "Rettet: grafiktestene målte ingen FPS, når testvinduet lå bagved",
 "Rettet: Opticon så sin egen starter som et nyt fund",
 "Optimering: vælg hvad du vil opnå, og se kun det",
 "Ny: 🏁 Benchmark – én stor test af CPU, hukommelse, disk og grafik med Opticon-score og historik",
 "Sammenlign med andre med samme processor og grafikkort (bærbar og stationær hver for sig), og del dit resultat",
 "Selvreparation: ikonet starter via en lille starter, der sætter den forrige version tilbage, hvis appen har en skrivefejl",
 "Automatisk tilbagerulning: starter en ny version ikke, sættes den forrige tilbage",
 "Rettet: 2.28 kunne ikke starte (et forkert anførselstegn)",
 "Sikring: opdateringer bliver tjekket for skrivefejl, før de installeres",
 "GPU-funktionerne virker nu også på AMD og Intel (fx Radeon 860M)",
 "AMD/Intel: Find den bedste strømtilstand afprøver Windows' 3 strømtilstande",
 "Watt for hele pc'en måles på batteri, belastning måles altid",
 "Ny: anbefaler producentens eget program til drivere og BIOS (fx Lenovo Vantage, Dell SupportAssist, HP Support Assistant)",
 "Spil-tilstand lukker nu kun programmer pænt (som krydset) og tvinger aldrig noget. Intet er valgt på forhånd",
 "Viser \"Lukket\" og \"Kunne ikke lukkes\"",
 "Gendannelse bliver nu bekræftet. Det, der fejler, prøves igen ved næste start",
 "Tilstande sættes tilbage, når Vagten slås fra, og før afinstallation",
 "OC-tjek: tydeligere om hvad der er målt, og skønnet fylder mindre",
 "Nyt navn: Opticon 🛡🤖 med nyt logo","Visuelt løft: blødere farver, nye knapper, afkrydsningsfelter og scrollbarer","Genvejene skifter selv navn til Opticon",
 "Ny: skøn efter trin 1 i OC-tjek: hvad overclock giver i FPS, strøm, varme og larm, og om det giver mening",
 "Rettet: testscenen kunne ikke starte (Edge kunne ikke bruge sin datamappe)",
 "Ny: nedtælling i testscenen og i appen",
 "Ny: ⚡ OC-tjek – mål udgangspunkt, lad NVIDIA finde dit overclock, og tjek at det holder i 5 min",
 "Ny: 📺 FPS ved Full HD, 2K og 4K med strøm og FPS pr. watt (under Optimering)",
 "Kan sammenligne med din GPU-profil i alle tre opløsninger",
 "Ny: 🎮 Tilstande – Spil og Fokus. Alt sættes tilbage bagefter",
 "Spil: lukker valgte baggrundsapps, dæmper beskeder og kan bruge din GPU-profil",
 "Fokus: 25/50/90 min, dæmp beskeder og bloker valgte sider",
 "GPU-testen gendanner nu altid strømgrænsen, også hvis appen lukkes midt i testen",
 "Rettet: Vagten blev vist som 'kører ikke', selv om den kørte",
 "Rettet: '301 nye ting' efter en genstart af Vagten",
 "Tal fra anmeldelser, når datasættet ikke har dit grafikkort (fx RTX 3070 Ti)"]
open(R+'version.json','w',encoding='utf-8').write(json.dumps({'version':ver,'date':'2026-11-24','notes':notes,'files':files},ensure_ascii=False,indent=2))
print(files)
