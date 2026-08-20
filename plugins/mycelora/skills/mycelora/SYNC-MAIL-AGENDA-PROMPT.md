---
name: mnemos-sync-mail-agenda
description: Collecte auto mails + agenda + contacts → Mycelora (toutes les 2h via Mail.app et Calendar.app)
---

# TEMPLATE — Adapter les valeurs entre {{ }} avant de créer la tâche
# Valeurs à remplacer : {{MAIL_ACCOUNT}}, {{MAILBOX}}, {{USER_EMAIL}}, {{USER_EMAIL_ALT}}, {{CALENDARS}}, {{USER_UUID}}

Tu es l'agent de collecte automatique Mycelora. Mission : récupérer mails récents + RDV depuis Mail.app et Calendar.app (macOS), les injecter dans Mycelora, enrichir les contacts, trier les orphelins.

## Compatibilité multi-provider
Mail.app et Calendar.app agrègent tous les comptes configurés (Google, Outlook, Exchange, iCloud). La collecte fonctionne quel que soit le provider. Les paramètres ci-dessous sont spécifiques à l'utilisateur courant.

## Contexte utilisateur (adapter par user)
- Mail.app : compte "{{MAIL_ACCOUNT}}" = {{USER_EMAIL}}
- Mailbox mails : "{{MAILBOX}}"
- Calendar.app : calendriers valides = { {{CALENDARS}} }
- Mycelora user ID : {{USER_UUID}}
- IMPORTANT : utiliser Desktop Commander (mcp__Desktop_Commander__*) pour AppleScript et fichiers, PAS les outils Bash du sandbox
- NOTE : les connecteurs natifs gcal_* et gmail_* ne sont PAS accessibles depuis les scheduled tasks. Utiliser AppleScript via Desktop Commander.

## RÈGLE ANTI-BOUCLE (CRITIQUE)
- Chaque étape s'exécute UNE SEULE FOIS. Pas de retry, pas de "rappeler une seconde fois".
- Si une étape échoue, logger l'erreur et passer à la suivante.
- Si un AppleScript timeout (>60s), passer à l'étape suivante.
- Maximum total : 25 appels d'outils pour tout le run. Au-delà, s'arrêter et logger.

## Étape 1 : Collecter les mails des 3 dernières heures via fichier TSV (max 10)
L'AppleScript filtre les mails reçus dans les 3 dernières heures (marge sur le cron 2h) et DOIT écrire dans /tmp/mycelora_mails.tsv (jamais en stdout direct).
Timeout : 90000ms.

Script osascript via mcp__Desktop_Commander__start_process :
```
osascript -e '
tell application "Mail"
  set outFile to POSIX file "/tmp/mycelora_mails.tsv"
  set fd to open for access outFile with write permission
  set eof of fd to 0
  set cutoffDate to (current date) - (3 * hours)
  set allMsgs to (every message of mailbox "{{MAILBOX}}" of account "{{MAIL_ACCOUNT}}" whose date received >= cutoffDate)
  if (count of allMsgs) > 10 then set allMsgs to items 1 thru 10 of allMsgs
  repeat with m in allMsgs
    try
      set mid to message id of m
      set subj to subject of m
      set sndr to sender of m
      set dt to date received of m
      set yr to year of dt
      set mo to month of dt as integer
      set dy to day of dt
      set hr to hours of dt
      set mn to minutes of dt
      set dtStr to (yr as text) & "-" & text -2 thru -1 of ("0" & mo) & "-" & text -2 thru -1 of ("0" & dy) & "T" & text -2 thru -1 of ("0" & hr) & ":" & text -2 thru -1 of ("0" & mn) & ":00"
      set bodyText to ""
      try
        set bodyText to content of m
        if length of bodyText > 300 then set bodyText to text 1 thru 300 of bodyText
      end try
      set bodyClean to do shell script "echo " & quoted form of bodyText & " | tr '\\n\\r\\t' '   ' | sed 's/[[:cntrl:]]//g'"
      set lineOut to mid & "\t" & subj & "\t" & sndr & "\t" & dtStr & "\t" & bodyClean
      write lineOut & linefeed to fd
    end try
  end repeat
  close access fd
end tell
return "OK"
'
```

Puis lire /tmp/mycelora_mails.tsv via mcp__Desktop_Commander__start_process + cat (PAS read_file qui ne supporte pas .tsv).
Détection envoyé/reçu : si sender contient "{{USER_EMAIL}}" ou "{{USER_EMAIL_ALT}}" → mail_sent, sinon → mail_received.

## Étape 2 : Collecter les événements agenda via fichier TSV
Fenêtre : 5 jours avant aujourd'hui → 5 jours après.

BUGS CONNUS Calendar.app AppleScript :
- NE PAS utiliser `uid of event` → erreur -10006. Utiliser `id of event` à la place.
- Utiliser la clause `whose start date >= startDate and start date <= endDate` pour filtrer côté Calendar (rapide).
- NE PAS itérer tous les événements manuellement (trop lent, timeout garanti sur les calendriers avec 200+ events).
- Construire le résultat en mémoire (variable allLines), puis écrire d'un coup via `do shell script "printf ... > /tmp/mycelora_calendar.tsv"`.

Timeout : 90000ms.

Script osascript via mcp__Desktop_Commander__start_process :
```
osascript -e '
set today to current date
set startDate to today - (5 * days)
set endDate to today + (5 * days)
set allLines to ""
set evtCount to 0
set validCals to { {{CALENDARS}} }
tell application "Calendar"
  repeat with cal in calendars
    if name of cal is in validCals then
      try
        set filteredEvts to (every event of cal whose start date >= startDate and start date <= endDate)
        repeat with e in filteredEvts
          try
            set eid to id of e
            set summ to summary of e
            set sd to start date of e
            set ed to end date of e
            set loc to ""
            try
              set loc to location of e
            end try
            set yr to year of sd
            set mo to month of sd as integer
            set dy to day of sd
            set hr to hours of sd
            set mn to minutes of sd
            set sdStr to (yr as text) & "-" & text -2 thru -1 of ("0" & mo) & "-" & text -2 thru -1 of ("0" & dy) & "T" & text -2 thru -1 of ("0" & hr) & ":" & text -2 thru -1 of ("0" & mn) & ":00"
            set yr2 to year of ed
            set mo2 to month of ed as integer
            set dy2 to day of ed
            set hr2 to hours of ed
            set mn2 to minutes of ed
            set edStr to (yr2 as text) & "-" & text -2 thru -1 of ("0" & mo2) & "-" & text -2 thru -1 of ("0" & dy2) & "T" & text -2 thru -1 of ("0" & hr2) & ":" & text -2 thru -1 of ("0" & mn2) & ":00"
            set allLines to allLines & eid & "\t" & summ & "\t" & sdStr & "\t" & edStr & "\t" & loc & linefeed
            set evtCount to evtCount + 1
          end try
        end repeat
      end try
    end if
  end repeat
end tell
do shell script "printf " & quoted form of allLines & " > /tmp/mycelora_calendar.tsv"
return "OK - " & evtCount & " events"
'
```

Puis lire /tmp/mycelora_calendar.tsv via mcp__Desktop_Commander__start_process + cat.

## Étape 3 : Injecter dans Mycelora via mnemos_ingest_events
Appeler mcp__mnemos__mnemos_ingest_events UNE SEULE FOIS avec :
- userId : "{{USER_UUID}}"
- events : tableau de TOUS les événements (mails + RDV), max 30

Pour les mails : source "gmail", event_type "mail_sent" ou "mail_received" (selon détection), event_id = message id, subject, body_preview = body extrait, participants = [email expéditeur], event_timestamp = date du mail.
Pour les RDV : source "google_calendar", event_type "meeting_created", event_id = id Calendar, subject = summary, event_timestamp = start date, metadata = {location, end_date}.

La dedup est automatique (contrainte UNIQUE sur user_id + source + event_id). Les doublons sont ignorés sans erreur.

## Étape 4 : Traiter avec Haiku via mnemos_process_events
Appeler mcp__mnemos__mnemos_process_events UNE SEULE FOIS avec :
- userId : "{{USER_UUID}}"
- limit : 20

Haiku évalue la pertinence de chaque événement, crée des atomes pour les importants, skip les newsletters/spam. Ne PAS rappeler. Les événements restants seront traités au prochain run.

## Étape 5 : Enrichir les contacts
Pour les 10 premiers mails dont l'expéditeur n'est PAS {{USER_EMAIL}} et n'est PAS noreply/newsletter/notification/invoice/substack/surveycircle/hubspotemail/scaleway :
Appeler mcp__mnemos__mnemos_upsert_contact avec name (extrait du sender avant le <email>), email, notes "Dernier mail : [subject] ([date])".
Maximum 10 appels upsert_contact.

## Étape 6 : Trier les atomes orphelins via mnemos_admin
Appeler mcp__mnemos__mnemos_admin UNE SEULE FOIS avec :
- action : "triage_atoms"
- userId : "{{USER_UUID}}"
- autoAssign : true
- limit : 20

## Étape 7 : Connexions sémantiques (SIMPLIFIÉ)
Sélectionner les 5 sujets les plus distincts parmi les mails traités à l'étape 4.
Si process_events a retourné processed=0 ou atoms_created=0, SAUTER cette étape.
Pour chaque sujet : UN appel mcp__mnemos__mnemos_search_atoms (limit 3).
Si >= 2 résultats avec similarity > 0.65 et de sources différentes (email ↔ calendar, ou received ↔ sent) : créer UNE connexion (type "concerne" par défaut, "confirme" si même fil received↔sent).
Maximum 5 connexions par run.

## Étape 8 : Log final
Logger en une ligne : "Sync : X mails (Y reçus, Z envoyés) + W RDV | Injectés: N | Atomes créés: P | Contacts: C | Triés: T | Connexions: K"