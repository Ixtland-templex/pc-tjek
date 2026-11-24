import hashlib, json, re, datetime
R='/home/claude/pc-tjek/'
rd=lambda f: open(R+f,encoding='utf-8-sig').read().replace('\r\n','\n')
ver='2.57'
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
# Kun nyhederne i DENNE version vises i appen. Ældre punkter står i historikken på GitHub.
notes=["Strømtesten kan ikke længere hænge: Opticon holder selv øje med testen og lukker den, hvis den går i stå, og sætter strømtilstanden tilbage",
 "Målinger af batteri og GPU-belastning og skift af strømtilstand kører nu ved siden af testen, så et langsomt Windows-kald ikke kan låse den",
 "Testvinduet siger til, hvis Opticon ikke svarer (luk med Alt+F4)",
 "Rettet: Hardware-accelereret GPU-planlægning vises nu korrekt"]
open(R+'version.json','w',encoding='utf-8').write(json.dumps({'version':ver,'date':'2026-11-24','notes':notes,'files':files},ensure_ascii=False,indent=2))
print(files)
