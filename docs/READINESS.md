> **Тарихи кезеңнің есебі.** Қазіргі Vercel/Supabase нұсқасы мен нақты жариялау тәртібі: [VERCEL-RELEASE.md](VERCEL-RELEASE.md). Төмендегі ескі сілтемелер мен тест сандары қазіргі іске қосу мәртебесін білдірмейді.

# Ustaz BilimAI: backup, staging және жариялауға дайындық

> Соңғы күй: [FULL-PLATFORM.md](FULL-PLATFORM.md). Жаңа сайтта тұрақты серверлік кабинеттер мен жеке база жасалды; 80 тест. Интернетке ашу workspace әкімшілігінің `sites_publish_disabled` қатесімен тоқтаған. Төмендегі жазбалар — бұрынғы дайындық кезеңінің тарихы.

> Жаңа нұсқау: backup, hosted staging және PostgreSQL орнату тоқтатылды. Браузерден ашылатын бөлек сынақ нұсқасы дайын: [PREVIEW.md](PREVIEW.md). Қазіргі автоматты тест саны — 71. Төмендегі 67 тест пен Production дайындық шарттары алдыңғы кезеңнің есебі ретінде сақталған; олар Preview қарауға кедергі емес.

Тексеру күні: **2026-10-26**. Жұмыс [draft PR №1](https://github.com/sss270186-cyber/ustaz-bilimai/pull/1) ішінде. **Production-ға жариялауға әзірге дайын емес: нақты backup/restore және hosted staging қабылдауы аяқталмаған.**

## Орындалғаны

| Бағыт | Нәтиже және дәлел |
|---|---|
| GitHub құрылымы | `main` әлі `f9cc0a518d326e0831b152e1e88b643175e5a597`; PR бөлек `codex/stage1-information-measurement` тармағында, draft, merged=false |
| Код резерві | Бұрынғы Git bundle үшін `git bundle verify` өтті: толық тарих бар. Бұл DB/Auth backup емес |
| Production-ға қатысты diff | Жаңа JS интерфейс, Vercel API, private grading/RLS және бес қосымша SQL миграция; бастапқы `app.py` өзгермеген. Production-да ешбір миграция орындалмаған |
| Backup рәсімі | [BACKUP.md](BACKUP.md): Free шектеуі, Auth, RLS, дерек, Storage, конфигурация, шифрлау, checksum және restore қабылдау шарттары |
| Read-only inventory | [ops/backup-inventory.sql](../ops/backup-inventory.sql): Auth/profile саны мен жеке aggregate fingerprint; RLS/grants, trigger, функция, extension, publication; `READ ONLY` транзакция, соңында ROLLBACK. Synthetic PGlite-де орындалды, дерек өзгермеді |
| Таза staging дайындамасы | [ops/staging-bootstrap.sql](../ops/staging-bootstrap.sql): тек бос жаңа staging, guard, profiles RLS, клиенттен promotion/тіркеуге тыйым. Production үшін қолданылмайды |
| Браузердегі staging қадамдары | [STAGING.md](STAGING.md): бөлек Supabase, synthetic teacher, 001–005, Preview branch variables, қабылдау тізімі |
| Preview оқшаулауы | Vercel Preview-де `BILIMAI_STAGING_SUPABASE_URL` міндетті; actual/expected origin сәйкес емес не белгілі Production ref болса API 503 береді. Тесттер **бірде-бір Supabase network call болмағанын** тексереді |
| Құпия кілттер | Клиент `/api/config` арқылы тек URL/publishable key алады. Service role тек серверлік оқушы admin функциясында. Backup/.dump/.vercel файлдары gitignore-де, сайттың static allowlist-іне кірмейді |
| Оқу мазмұны | 19 теория, 38 B + 190 C = 228 тапсырма. Бұрынғы терең аудитте 101 C жетілдірілген; [әр тақырып және әр тапсырма есебі](QUALITY-AUDIT.md) сақталған |
| Қауіпсіздік пен интерфейс | Серверлік grading, шешімнің тек submit-тен кейін ашылуы, қате жауап талдауы, оқушы нәтижелерінің оқшаулануы, мұғалімнің desktop/mobile нәтижелері жергілікті тексерілді |

## Осы сессияда орындалмағаны

- Нақты Production DB/Auth көшірмесі және Storage экспорты алынған жоқ; restore тексерілген жоқ.
- Production endpoint-ке сұрау жіберілген жоқ; нақты аккаунттар/дерек/пароль/API кілттері/конфигурация өзгертілген жоқ.
- Қазіргі құралдарда Supabase/Vercel басқару және авторизацияланған browser automation қолжетімді емес. Ортаның қолданбалық Supabase кілттері full PostgreSQL/Auth dump не Vercel configuration құқығын бермейді. Database-owner connection және басқару credentials берілмеген; олар чатқа сұралмайды.
- Бөлек hosted Supabase, Auth signup provider баптауы, Vercel branch-specific variables және жаңа Preview connection орнатылған жоқ. Қадамдар дайын, орындау дәлелі жоқ.
- Тірі Supabase Authentication, сақтау тұрақтылығы, нақты RLS/Storage/SMTP/Vercel build конфигурациясы қабылдау сынағынан өткен жоқ. Жергілікті Auth — эмулятор; PGlite hosted Supabase-тің толық backup/restore дәлелі емес.
- Бастапқы `profiles` DDL/RLS репозиторийде жоқ. Оның нақты өзіндік UPDATE/INSERT рұқсаттары, signup-trigger, `role` өрісінің қорғанысы және metadata-ға сенім артылмауы тірі schema inventory/жабық restore зертханасында тексерілуі керек. Қолданыстағы мұғалімдердің тізімі бірінші миграция алдында owner тарапынан расталады.
- Толық тапсырма редакторы және көп ұйымға арналған ownership моделі әлі жоқ. Қазіргі сервер оқушыларды байланыстыру үшін ортақ roster бере алады; бұл бірнеше ұйымға толық оқшауланған өнім деп көрсетілмейді.
- PR біріктірілген жоқ. Production deployment жасалған жоқ. Кодтың жергілікті дайын болуы жариялауға рұқсатты алмастырмайды.

## Автоматты тексерулер

2026-10-26 соңғы жергілікті нәтиже:

| Тексеру | Нәтиже |
|---|---|
| `npm test` | **67/67 өтті**; 61 бұрынғы тест + 3 API/Preview қорғанысы + 3 operations/RLS тесті |
| Grading/RLS | 228 дұрыс және 228 қате жауап; private field gating, нәтижелер, нұсқалар, рөл, жалған attempt, rate limit |
| `npm run check` | JavaScript синтаксисі, asset/HTML сәйкестігі, құпия/public шекарасы, static allowlist және барлық seed өтті |
| `npm run seed:check` | Бес миграцияның source/generator сәйкестігі өтті |
| `npm run test:programs` | 36 Python/SQL коды нақты орындалды; IP жауаптары Python `ipaddress` арқылы тексерілді |
| `npm run test:excel` | 12 Excel есебі HyperFormula-мен өтті, mixed references және формуланы көшіру қоса тексерілді |
| `npm run test:ui` | Chromium: 19 теория, 228 карточка, grading/gating/feedback, refresh-тен кейін нәтижелер, мұғалім desktop және 390 px mobile, аккаунт, оқушы оқшаулауы, ҚМЖ, private ops URL-дері өтті |
| `npm run test:css` | 12 HTML/CSS жауабы Chromium DOM/layout арқылы өтті |
| `git diff --check` | Өтті |
| `npm run test:staging` | **Орындалмаған** — бөлек endpoint және synthetic teacher credentials жоқ; Production-да іске қосылмайды |

Алғашқы шектеулі sandbox орындауында екі child-process тексеруі `EPERM` берді; рұқсат етілген жергілікті process режимінде толық қайта орындау өтті. Өнім кодының қатесі табылған жоқ. Microsoft Excel бағдарламасында жеке қолмен тексеру және сыртқы ресми ҰБТ күрделілік калибровкасы орындалған жоқ.

GitHub Actions сол командаларды push және pull_request оқиғаларында қайта орындайды; нақты соңғы commit статусы PR Checks бөлімінде көрінеді. Бұрынғы сапа аудитіндегі «61 тест» — сол кезеңдегі тарихи сан, ал осы кезеңде алты қауіпсіздік/operations тесті қосылды.

## Жариялау алдында міндетті дәлелдер

| Шарт | Қазіргі күй |
|---|---|
| Код/контент пен жергілікті сынақтар | Өтті |
| DB/Auth/Storage backup және екі шифрланған көшірме | Орындалмаған |
| Оқшауланған restore, UUID/пароль хеші/дерек/RLS/файл сәйкестігі | Орындалмаған |
| Тірі `profiles` және Auth signup аудиті | Орындалмаған |
| Synthetic hosted staging + нақты Preview байланысы | Орындалмаған |
| Нақты Auth, teacher create-user, RLS, сақтау, mobile қабылдауы | Орындалмаған |
| Production өзгерісінің нақты тізімі, жаңа fresh backup, rollback және бөлек пайдаланушы растауы | Күтіледі |

Келесі нақты әрекет: **Production Dashboard-та ref/Connect параметрлерін тексеріп, [BACKUP.md](BACKUP.md) бойынша өз компьютеріңізге backup алу.** Тек осы рәсімнің дәлелінен кейін оны «backup дайын» деп белгілеуге болады. Құпия деректер жіберілмейді; орындалған қадам, exit status және restore нәтижесі жеткілікті.

Production-ға рұқсат берілгенде де merge автоматты Vercel production deployment туғызуы мүмкін. Сондықтан migration/deploy реті staging қабылдауынан кейін жеке release жоспарында анықталады. Ақауда ескі deployment-ке оралу жаңа нәтижелерді жоюға себеп емес; `unt_*` кестелері DROP/TRUNCATE жасалмайды.
