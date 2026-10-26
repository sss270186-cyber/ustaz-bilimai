# Production-ды өзгертпей резервтік көшірме алу

Тексерілген күн: 2026-10-26. Бұл құжат — орындау нұсқаулығы. **Нақты DB/Auth backup әлі алынған жоқ және restore тексерілмеген.** PR №1 біріктірілмейді. Production SQL, аккаунт, пароль, API кілті, Auth баптауы және deployment өзгертілмейді.

## Қазір сақталғаны

- GitHub `main`: `f9cc0a518d326e0831b152e1e88b643175e5a597`.
- Жаңа платформаның тексерілген PR commit-і: `ac404f6be6f5c7572eac7434d8f11e5a30130ed6`.
- Бұрынғы кодтың Git bundle көшірмесі жергілікті қорғалған орында бар; `git bundle verify` толық тарихтың жарамдылығын растады. Ол DB, Auth, Vercel environment немесе Storage backup емес.
- `app.py` бастапқы нұсқамен бірдей. ҚМЖ және бұрынғы оқушы логинінің email пішімі сақталған.
- Бастапқы репозиторийде `profiles` DDL/RLS және Auth баптаулары жоқ. Оларды кодтан толық қалпына келтіру мүмкін емес: төмендегі inventory/dump міндетті.

## Free тарифіндегі дұрыс әдіс

Supabase Free үшін тұрақты, жоба сыртында сақталатын логикалық dump қолданылады. Dashboard-та ақылы жоспардағыдай жүктелетін күнделікті backup/PITR бар деп есептемеңіз. Table Editor → Export CSV жеке кестеге қосымша көшірме бола алады, бірақ Auth пароль хештерін, рөлдерді, RLS, триггерлерді, функцияларды және FK байланыстарын толық сақтамайды.

**Тек браузермен Free жобаның толық қалпына келетін backup-ын алу жолы бұл нұсқаулықта жоқ.** Браузерден параметрлерді алып, төмендегі экспортты өзіңіздің сенімді компьютеріңізде орындаңыз. Production-да Restore, Reset database, Delete project, Pause, пароль ауыстыру немесе `db push/db reset` қолданылмайды.

## 1. Браузердегі дайындық — ешнәрсені өзгертпеңіз

1. Supabase Dashboard-та **қолданыстағы Production** жобасын ашыңыз. Project Settings → General жерінен project ref пен аймақты жеке жазбаға сақтаңыз. Күтілетін ref: `kbnwfuvfnspanoomusmu`; экрандағы ref басқаша болса, жалғастырмас бұрын жобаны қайта анықтаңыз.
2. Database → Backups бөлімінде нақты қолжетімділікті қараңыз. Free-де жүктеу болмаса, CSV-ді толық backup деп қабылдамаңыз. Ешқандай restore батырмасын баспаңыз.
3. Жоғарғы **Connect** терезесін ашып, **Session pooler**, порт `5432` параметрлерін таңдаңыз. IPv6 қолжетімді болса Direct connection жарайды. Transaction pooler (`6543`) бұл рәсімге қолданылмайды.
4. Host, port, database, user параметрлерін жеке сақтаңыз. Database password — API service role кілтінен бөлек. Бұрын сақталған DB паролін пайдаланыңыз; ол белгісіз болса, осы жерде тоқтаңыз. Production паролін осы тапсырма аясында қалпына келтірмеңіз.
5. SQL Editor-де [ops/backup-inventory.sql](../ops/backup-inventory.sql) файлын **толық** орындаңыз. Ол `READ ONLY` транзакциясында жұмыс істеп, `ROLLBACK` арқылы аяқталады. Нәтижесін тек жеке backup қалтасына сақтаңыз. `profiles` болмағандықтан не рұқсаттан қате шықса, DDL арқылы «түзетпеңіз»; схеманы анықтау қажет.
6. Inventory соңындағы `exact_count_sql` бағаны кестелерді дәл санайтын `SELECT` мәтіндерін береді. Сол SELECT-терді орындап, нәтижелерін сақтаңыз. Бұл сандар restore салыстыруына керек.
7. Authentication → Users арқылы аккаунттар санын; Authentication баптауларынан signup, email provider, redirect URLs, SMTP, MFA/OAuth қолданылуын жеке тіркеңіз. Құпия мәндерді скриншотқа түсірмеңіз. Ешнәрсе ауыстырмаңыз.
8. Storage → Buckets: bucket атаулары, public/private күйі және файлдар бар-жоғын қараңыз. Database → Extensions/Publications: қосылған extension және Realtime тізімін сақтаңыз. Database Webhooks, Edge Functions және сыртқы интеграциялар бар болса, жеке тізімдеңіз.

Inventory тек агрегат fingerprint береді, бірақ оның нәтижесі де жеке сақталады. Пароль хештерін, токендерді, оқушы деректерін чатқа немесе GitHub-қа жібермеңіз.

## 2. Сенімді компьютерден экспорт

Supabase CLI, Docker Desktop және PostgreSQL client (`pg_dump`, `pg_restore`, `psql`) орнатылған болуы керек. `pg_dump` нұсқасы серверден ескі болмауы тиіс. Нұсқаларды `supabase --version`, `pg_dump --version` арқылы тіркеңіз. Командаларды Git репозиторийінен тыс орындаңыз. Төмендегі үлгі Bash үшін; Windows-та WSL/Git Bash пайдаланыңыз.

```bash
umask 077
mkdir -p ustaz-private-backup-2026-10-26
cd ustaz-private-backup-2026-10-26
set +x
read -r -s -p 'Production Session pooler URI (тек осы компьютерде): ' BACKUP_DB_URL
printf '\n'
export PGSSLMODE=require

supabase db dump --db-url "$BACKUP_DB_URL" -f roles.sql --role-only
supabase db dump --db-url "$BACKUP_DB_URL" -f schema.sql
supabase db dump --db-url "$BACKUP_DB_URL" -f data.sql --use-copy --data-only \
  -x 'storage.buckets_vectors' -x 'storage.vector_indexes'
```

Әр команданың exit status-ы `0` болуы керек; қате болса, кейінгі restore-ға өтпеңіз. URI ішінде DB паролі бар болса, арнайы таңбалары URL-encoded болуы қажет. URI shell history-ге жазылмайды, бірақ орындалатын процестің аргументінде болуы мүмкін: ортақ компьютер/CI логы қолданылмайды. `--debug` қоспаңыз. Бұл командалар жобаға миграция қолданбайды; олар dump оқиды. Тыныш уақытта орындаңыз: dump SELECT/қысқа metadata lock қолданады, DDL операцияларымен қатар жүргізбеңіз.

### Auth және басқарылатын схемаларды міндетті тексеру

CLI-дің әдеттегі **schema** dump-ы басқарылатын `auth`/`storage` объектілерін толық көшірмейді; жаңа Supabase жобасы оларды өзі жасайды. Сондықтан тек `schema.sql` жеткіліксіз. `data.sql` файлында Auth кестелерінің COPY бөлімдері барын мәндерін шығармай тексеріңіз:

```bash
python3 - <<'PY'
import pathlib,re
s=pathlib.Path('data.sql').read_text()
for schema,table in [('auth','users'),('auth','identities'),('public','profiles')]:
    found=bool(re.search(r'COPY\s+"?'+schema+r'"?\."?'+table+r'"?\s*\(',s,re.I))
    print(schema+'.'+table+': '+('COPY бар' if found else 'ЖОҚ — тоқтаңыз'))
    if not found: raise SystemExit(1)
PY
```

Сервер нұсқасы мен CLI мінез-құлқына қарай export құрамы өзгере алады. Auth COPY бөлімдері жоқ болса, backup толық деп саналмайды. Барлығының соңына дейін экспортталғанын exit status, файл өлшемі және restore сынағы ғана растайды.

Қосымша **бір snapshot-тан толық PostgreSQL custom archive** алыңыз. Бұл auth/storage ішіндегі арнайы функция/триггер/саясаттарды да жоғалтпай сақтауға арналған. Парольді команданың ішіне жазбай, `pg_dump --password` сұрауында енгізіңіз:

```bash
read -r -p 'Session pooler host: ' PGHOST
read -r -p 'Session pooler user: ' PGUSER
export PGHOST PGUSER
export PGPORT=5432 PGDATABASE=postgres
export PGOPTIONS='-c default_transaction_read_only=on -c lock_timeout=5000'
pg_dump --password --format=custom --file=full.dump
pg_restore --list full.dump > full-toc.txt
unset PGOPTIONS
```

Толық archive-те managed Supabase объектілері де бар. Оны жаңа hosted жобаға `pg_restore --clean` арқылы соқыр түрде жүктемеңіз. Ол restore маманына объектілерді салыстырып/таңдап алуға арналған қосымша толық дәлел; hosted restore үшін төмендегі Supabase-ке бейімделген файлдар пайдаланылады. Қате болса `--no-privileges` арқылы RLS/grants-ты жоғалтып «өткізбеңіз».

Migration history бар болса, оны да **жеке** сақтаңыз. Inventory-де `supabase_migrations` схемасы жоқ болса, келесі екі команданы орындамаңыз:

```bash
supabase db dump --db-url "$BACKUP_DB_URL" -f history_schema.sql --schema supabase_migrations
supabase db dump --db-url "$BACKUP_DB_URL" -f history_data.sql --use-copy --data-only --schema supabase_migrations
unset BACKUP_DB_URL PGHOST PGUSER PGPORT PGDATABASE
```

Схема/рөл/дерек бөлек алынатындықтан, олардың бәрі бір ортақ snapshot емес. Деректер бір `data.sql` dump ішінде келісімді snapshot-тан алынады; рәсім кезінде DDL/рөл өзгерісі болмауы керек. `full.dump` бір snapshot-ты сақтайды. Inventory уақыты басқа болғандықтан қатар жүретін жазбалар count/fingerprint айырмасын бере алады; айырманы зерттемей restore өттi деп белгілемеңіз.

## 3. SQL-ден тыс сақталатын бөліктер

| Бөлік | Сақтау тәсілі | Restore шектеуі |
|---|---|---|
| Auth users/identities, пароль хештері | Auth деректері бар `data.sql` және `full.dump` | Сол UUID мен хештер сақталуы керек; жаңа JWT кілтімен қайта кіру талап етіледі |
| Қолданба кестелері, FK, sequence, индекс, RLS/grants, функциялар | `schema.sql`, `roles.sql`, `data.sql`, inventory, толық archive | `auth/storage` ішіндегі custom объектілер жеке салыстырылады |
| Storage файлдары | Dashboard арқылы әр файлды Download; көп болса ресми Storage/S3 export құралымен | SQL тек metadata сақтайды; файлдың өзі, path және SHA-256 бөлек қажет |
| Auth/SMTP/OAuth/redirect/Realtime/Edge Function баптауы | Құпия емес конфигурация тізімі; secrets тек password manager-де | DB dump толық жоба конфигурациясын алмастырмайды |
| Vault/pgsodium/encrypted columns, MFA қолданылса | Қолданылуын анықтап, ресми encryption-root-key restore рәсімін жоспарлау | Root key жетпесе ciphertext болғанымен қалпына келтіру толық емес; кілтті GitHub/чатқа салмаңыз |
| Custom LOGIN рөлдерінің паролі | Password manager-де бөлек | Dump оларды сақтайды деп сенуге болмайды; оқшауланған target-та бөлек тағайындалады |
| Бұрынғы браузер нәтижелері | Әр пайдаланушының `localStorage.bilimai_results` дерегінің жеке экспорты | Supabase dump оны қамтымайды; браузер деректерін тазаламаңыз |
| Vercel | Қазіргі deployment ID, git SHA, domain mapping, env атаулары | Нақты мәндер тек Vercel/password manager-де; dump ішінде жоқ |

Кез келген файлды көшіргенде bucket/path, өлшемі және checksum тіркеледі. Үлкен Storage-ты браузермен толық шығара алмасаңыз, «толық backup» белгісін қоймаңыз.

Файлдарда оқушы деректері, пароль хештері және токендер болуы мүмкін. Қалтаны шифрлап, екі бөлек қорғалған орынға сақтаңыз. Шифрлау паролін архивпен бірге сақтамаңыз. macOS-та `shasum -a 256`, Linux-та төмендегіні қолданыңыз:

```bash
sha256sum roles.sql schema.sql data.sql full.dump full-toc.txt > SHA256SUMS
sha256sum -c SHA256SUMS
```

Storage/history/config файлдары бар болса оларды да checksum тізіміне қосыңыз. Hash сәйкес келуі — файл бүтіндігінің тексеруі; ол restore жарамдылығын өздігінен дәлелдемейді. Backup, SQL output және `.dump/.backup` файлдары ашық репозиторийге қосылмайды.

## 4. Қалпына келтіруді тексеру жоспары

**Target тек оқшауланған restore зертханасы. Production URL/DB connection ешқашан restore командасына берілмейді.** Нақты аккаунт көшірмелері бар restore зертханасын Vercel Preview-ге қоспаңыз. Тұрақты staging-де тек synthetic пайдаланушылар болуы керек.

1. Supabase-тің бөлек бос quarantine жобасын немесе өз компьютеріңіздегі толық Supabase stack ашыңыз. Free жоба лимиті екінші бұлттық жобаға кедергі болса, жергілікті stack қолданыңыз; тарифті автоматты ауыстырмаңыз. PGlite толық hosted Auth restore-ды алмастырмайды.
2. Source пен target ref/host әртүрлі екенін жеке тексеріңіз. Target-та email/SMS, OAuth, webhook, cron және сыртқы қызметтерге әрекеттер қосылмайды. Production JWT/signing/API кілттерін тұрақты staging-ке көшірмеңіз.
3. `SHA256SUMS` тексеріңіз. PostgreSQL/Auth schema нұсқаларын, extensions, roles, Vault/encryption қолданылуын салыстырыңыз. Dump ішіндегі webhook URL/cron/secrets-тің қалпына келгеннен кейін сыртқа әрекет жібермеуін қамтамасыз етіңіз; бұл шарт орындалмайынша restore-ды іске қоспаңыз.
4. Қолжетімді `auth/storage` custom саясат/триггер/функцияларын inventory және `full.dump` анықтамаларымен салыстырыңыз. Жаңа жобаның managed объектілерін түгел ауыстырмай, custom бөлігін ғана review жасап дайындаңыз. Шешілмеген permission/extension/encryption айырмасы болса тоқтаңыз.
5. Сенімді компьютерде, **тек тексерілген target** үшін Supabase-тің ресми restore реті: `roles.sql` → `schema.sql` → trigger-лерді осы restore сеансы үшін өшіру → `data.sql`. Бір транзакция және `ON_ERROR_STOP` қолданылады:

```bash
read -r -s -p 'ТЕК quarantine target URI: ' RESTORE_DB_URL
printf '\n'
# Алдымен URI host/user project ref-ін Production-мен жеке салыстырыңыз.
psql --dbname "$RESTORE_DB_URL" --single-transaction --set ON_ERROR_STOP=1 \
  --file roles.sql --file schema.sql \
  --command 'SET LOCAL session_replication_role = replica' --file data.sql
unset RESTORE_DB_URL
```

`replica` trigger/FK тексеруін уақытша өшіреді; ресми тәсілде Auth деректерін қосарлап түрлендірмеуге арналған. Сондықтан келесі FK/orphan және custom Auth trigger тексеруі міндетті. Қате болғанда барлық restore транзакциясы кері қайтады. Қатені жаппай елемеу, Production-да DROP/TRUNCATE/RESTORE жасау немесе барлық trigger-ді тұрақты өшіру қолданылмайды. Role ownership қатесін нақты жол бойынша review жасаңыз, backup түпнұсқасын өзгертпеңіз.

6. Custom `auth/storage` объектілерін және migration history-ді review жасалған жеке транзакциялармен қалпына келтіріңіз. Қайталанып restore жасамаңыз; сәтсіз target-ты талдамай үстінен баспаңыз.
7. Сол inventory-ді target-та орындаңыз. Әр app кестесінің дәл саны, Auth users/identities саны, UUID, пароль-хеш aggregate fingerprint, profile fingerprint, RLS/grants, FK orphan, sequence келесі мәні, extension және функциялар салыстырылады. Managed нұсқалық айырмалар құжатталады.
8. Storage файлдарының path/өлшем/SHA-256 сәйкестігін тексеріңіз. Vault/MFA қолданылса decrypt/Auth smoke-ін аяқтамай restore өтті демеңіз.
9. Бұрыннан бар логинді өзгеріссіз сақтау үшін аккаунт иесі өз белгілі паролін **тек quarantine login бетінде** өзі енгізіп тексереді; паролін чатқа жібермейді. Шығыс email/SMS сөндірулі қалады. Жаңа JWT кілтімен бұрынғы session-ның жарамсыз болуы қалыпты, парольмен қайта кіру жұмыс істеуі керек.
10. Нәтижені жеке журналға жазыңыз: source/target ref, уақыт, export/client нұсқасы, checksum, counts/fingerprints, тексерілген RLS/Auth/Storage, қателер, restore ұзақтығы. Журналда пароль/хеш/token болмайды. Осы дәлелдерсіз backup **«алынған, бірақ тексерілмеген»** күйінде қалады.

Quarantine аяқталған соң дербес деректері бар ортаны ашық Preview-ге пайдаланбаңыз. Кәдімгі staging-ті бөлек таза жобада немесе жеке рұқсатпен қайта дайындалған ортада, тек synthetic аккаунттармен жүргізіңіз. Production дерегін тазалау бұл рәсімге кірмейді.

## 5. Келесі кезеңге өту шарты

- [ ] DB/Auth көшірмесі алынды, auth.users/auth.identities және барлық қолданба кестелері қамтылған.
- [ ] RLS/grants/custom managed объектілер, Storage және конфигурация тізімі сақталған.
- [ ] Екі шифрланған көшірме және тексерілген checksum бар.
- [ ] Оқшауланған restore, Auth login және дерек сәйкестігі өтті.
- [ ] `profiles` саясатында студенттің `role` өзгертуі/бөтен профильді оқуы шектелгені тексерілді.

Таза synthetic staging-ті дайындауға болады, бірақ Production-ға көшу үшін барлық шарт орындалуы керек. Келесі қадамдар: [STAGING.md](STAGING.md).

## Ресми дереккөздер

- [Supabase — Database Backups: Free, Storage шектеуі](https://supabase.com/docs/guides/platform/backups)
- [Supabase — Backup and Restore using CLI: export/restore, custom managed objects және encryption](https://supabase.com/docs/guides/platform/migrating-within-supabase/backup-restore)
- [Supabase — Auth users және пароль хештерін көшіру](https://supabase.com/kb/troubleshooting/migrating-auth-users-between-projects)
- [PostgreSQL — pg_dump: snapshot, archive және шектеулер](https://www.postgresql.org/docs/current/app-pgdump.html)
