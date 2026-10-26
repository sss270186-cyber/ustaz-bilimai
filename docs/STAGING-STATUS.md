> **Тарихи кезеңнің есебі.** Қазіргі Vercel/Supabase нұсқасы мен нақты жариялау тәртібі: [VERCEL-RELEASE.md](VERCEL-RELEASE.md). Төмендегі ескі сілтемелер мен тест сандары қазіргі іске қосу мәртебесін білдірмейді.

> 2026-10-26: бұл файл тарихи күйді сақтайды. Қазіргі нәтиже: [READINESS.md](READINESS.md); қолмен орындалатын backup: [BACKUP.md](BACKUP.md); synthetic staging және Preview: [STAGING.md](STAGING.md). Нақты DB/Auth backup/restore және hosted staging әлі орындалмаған. Осы сессияда Production endpoint-ке сұрау жіберілген жоқ.

# Staging жұмысының мәртебесі

## Расталғаны

- Пайдаланушы backup, бөлек staging және қабылдау сынағына рұқсат берді. Соңғы нұсқауы бойынша Production-ға кез келген өзгеріс тек бөлек нақты растаудан кейін енгізіледі.
- Бірінші кезең draft PR №1-де: https://github.com/sss270186-cyber/ustaz-bilimai/pull/1
- GitHub Actions-тың бірінші кезеңдегі тесттері өткен. GitHub commit status Vercel-дің Preview deployment-ті сәтті құрастырғанын растады. Бұл оның бөлек staging базасына қосылғанын растамайды.
- Тірі Supabase аудиті тек GET сұрауларымен жүргізіледі; SQL миграциясы қолданылмайды, аккаунттар өзгертілмейді.
- Нақты staging қабылдау скрипті және Production-ға бағытталудан қорғайтын тексерулер қосылды.

## Қолжетімділікке тәуелді жұмыстар

Бұл ортада Supabase және Vercel басқару интеграциялары `DISABLED_BY_ADMIN / NOT_AVAILABLE` күйінде. Бар кілттер — қолданыстағы Supabase жобасының publishable және service_role кілттері. Management token, database-owner connection, Vercel token және бөлек staging жоба деректері жоқ.

Осы себеппен толық DB/Auth backup, hosted staging құру/қалпына келтіру, SQL миграциясын қолдану және Preview-ді staging-ке қосу әлі жасалған жоқ. Production-ға көшу қабылдау қадамдары өткеннен кейін де бөлек нақты растаусыз орындалмайды. Бұрыннан бар адамның құпиясөзін өзгерту не тірі жобада synthetic аккаунт жасау арқылы бұл шектеу айналып өтілмейді.

Қажетті қорғалған айнымалылар және сынақ тәртібі: `docs/ROLLOUT.md` соңындағы екі бөлім.

## Жергілікті тексеру

Барлығы 27 тест өтті: алғашқы 22 тест және staging guard/cleanup-ке арналған 5 тест. JavaScript синтаксисі, asset сілтемелері және SQL seed сәйкестігі де өтті. Нақты hosted staging smoke-і орындалған жоқ: staging endpoint пен сынақ мұғалімінің protected credentials-і берілмеген.

Production read-only аудитінің соңғы нәтижесі: 2 профиль (1 teacher, 1 student), anonymous profile rows — бос, `unt_topics` — 404. Бұл толық backup немесе ескі саясаттардың толық аудиті болып саналмайды.

Қауіпсіз авторизация жолдары және рұқсаттар: `docs/AUTHORIZATION.md`. Интеграциялар соңғы тексеруде де әкімші тарапынан өшірілген; басқару токендері мен database connection берілмеген.
