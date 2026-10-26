# Бөлек Supabase және Vercel Preview: браузердегі қадамдар

2026-10-26. **Hosted staging әлі құрылмаған және нақты Auth/Vercel қабылдау сынағы өтпеген.** Төмендегі қадамдар оны қауіпсіз дайындауға арналған. Production дерекқоры, аккаунттар, кілттер және environment өзгермейді. PR №1 draft күйінде қалады.

Алдымен [BACKUP.md](BACKUP.md) бойынша көшірме мен restore жоспарын дайындаңыз. Restore зертханасында нақты деректің көшірмесі болуы мүмкін; бұл құжаттағы тұрақты staging тек **synthetic** деректермен іске қосылады.

## 1. Таза Supabase staging

1. Dashboard → New project. Атауы: `ustaz-bilimai-staging`. Production жобасын Rename/Reset/Restore арқылы пайдаланбаңыз. Тариф пен жоба лимиті шығын талап етсе, ақылы өзгерісті автоматты жасамаңыз; жергілікті сынақты жалғастыруға болады.
2. Жаңа DB паролін password manager-де сақтаңыз. Жобаның толық дайын болғанын күтіңіз. Project ref Production-ның `kbnwfuvfnspanoomusmu` ref-інен өзгеше болуы керек.
3. Authentication → Sign In / Providers немесе General Configuration бөлімінде **Allow new users to sign up** және **Allow anonymous sign-ins** опцияларын **staging-де** өшіріңіз. Мұғалім оқушыларды сервердің admin API-імен тіркейді. Public signup жабық болғанымен admin create-user жұмыс істейтінін қабылдау сынағында тексеріңіз.
4. Тек staging SQL Editor терезесінде, Auth аккаунттары әлі жоқ кезде, бір орындау блогына `SET bilimai.environment = 'staging';` жолын және [ops/staging-bootstrap.sql](../ops/staging-bootstrap.sql) файлын толық қойып орындаңыз.
5. Bootstrap `profiles` кестесін, тек өз профилін оқитын RLS саясатын жасайды. Клиент INSERT/UPDATE/DELETE жасай алмайды; рөлді өзгерту тек сенімді сервер/DB owner арқылы. Бұл **Production миграциясы емес** және бұрынғы `profiles` кестесінің үстінен орындалмайды. GUC белгісі оператордың растауы ғана; жоба ref-ін өзіңіз тексеру міндетін алмастырмайды.
6. Authentication → Users → Add user/Create user арқылы **жасанды** мұғалім жасаңыз: мысалы `qa_teacher@example.com`, жеке мықты тест паролі, email confirmed. Шақыру email-ін жібермеңіз. Парольді чатқа/репозиторийге жазбаңыз. UUID-ін көшіріңіз.
7. Сол staging SQL Editor-де мұғалім профилін жасаңыз. `TEACHER_UUID` орнына жаңа synthetic Auth пайдаланушысының UUID-ін қойыңыз:

```sql
begin;
insert into public.profiles(id, username, full_name, class_name, role)
values ('TEACHER_UUID'::uuid, 'qa_teacher', 'Staging сынақ мұғалімі', '11', 'teacher');
commit;
```

Бұл owner операциясы тек жаңа staging-де орындалады. Студентке осы SQL немесе owner құқығы берілмейді. Auth metadata-дағы `role=teacher` жаңа жүйеде мұғалім өкілеттігін бермейді.

## 2. Бес миграцияны ретімен орындау

Барлық файл [PR №1 тармағынан](https://github.com/sss270186-cyber/ustaz-bilimai/tree/codex/stage1-information-measurement/supabase/migrations) алынады. GitHub-та файлдың **Raw** мәтінін ашып, толық көшіріңіз. Қысқартылған diff-ті SQL Editor-ге салмаңыз.

| Рет | Файл | Нәтиже |
|---:|---|---|
| 1 | `202610180001_learning.sql` | Оқу кестелері, жабық answer schema, RLS және RPC; бар synthetic teacher-ді тізімге көшіру |
| 2 | `202610180002_measurement_seed.sql` | Ақпаратты өлшеу тақырыбының бастапқы 12 есебі |
| 3 | `202610180003_answer_formats.sql` | Сан/мәтін/тізбек жауаптары, code және түсіндірме |
| 4 | `202610180004_full_curriculum.sql` | Барлық 19 тақырып, 228 тапсырма |
| 5 | `202610180005_quality_review.sql` | 101 C жаңартуы, қате жауап талдауы және тапсырма нұсқалары |

Әр файлды жеке орындап, Success нәтижесін және уақытын белгілеңіз. SQL Editor CLI migration history-ді автоматты жүргізбейді: файл аты, SHA-256, орындау уақыты мен нәтижесін жеке журналда сақтаңыз. Кейін CLI-ге ауысқанда алдымен сол журналмен history-ді сәйкестендіріңіз; бес файлды қайта `db push` етпеңіз. Файл ішіндегі BEGIN/COMMIT сақталады. Қате болса кейінгі файлға өтпеңіз, кестелерді жойып қайта бастамаңыз.

DB owner тексеруі:

```sql
begin transaction read only;
select count(*) as topics from public.unt_topics; -- 19
select count(*) as tasks from public.unt_tasks; -- 228
select t.id, count(*) filter (where q.level='B') as b,
       count(*) filter (where q.level='C') as c
from public.unt_topics t join public.unt_tasks q on q.topic_id=t.id
group by t.id order by t.id; -- әр жолда 2 және 10
select count(*) as private_keys from unt_private.answer_keys; -- 228
select count(*) as registered_teachers from public.unt_teachers; -- 1 synthetic teacher
rollback;
```

API Settings → Exposed schemas ішінде `unt_private` **болмауы керек**. Data API өшірілмейді: қолданба `public` RPC-лерін пайдаланады. DB owner-дің answer_keys оқи алуы — қалыпты; клиенттің оқуына тыйым салынады.

## 3. Vercel Preview-ді staging-ке қосу

Қолданыстағы Vercel жобасы → Settings → Environment Variables. **Production scope-ын және main production branch-ін өзгертпеңіз.** Төмендегі төрт мәнге тек **Preview**, нақты branch `codex/stage1-information-measurement` таңдаңыз:

| Айнымалы | Мән | Браузерге берілуі |
|---|---|---|
| `SUPABASE_URL` | Жаңа staging Project URL | Ашық endpoint ретінде беріледі |
| `SUPABASE_PUBLISHABLE_KEY` | Сол staging publishable key | Auth үшін ашық; қауіпсіздігі RLS-ке сүйенеді |
| `SUPABASE_SERVICE_ROLE_KEY` | Сол staging legacy service_role JWT | **Тек серверде**, sensitive/secret ретінде |
| `BILIMAI_STAGING_SUPABASE_URL` | Жоғарыдағы staging URL-мен дәл бірдей origin | Preview-дің қате базаға қосылуын тоқтататын серверлік guard |

Key мәндерін Supabase staging жобасының API Keys бөлімінен тікелей Vercel қорғалған өрісіне көшіріңіз. Кодтағы admin endpoint legacy service_role JWT форматын қолданады; `sb_secret_…` кілтін оны қолдайды деп тексерусіз алмастырмаңыз. Ешбір құпияға `VITE_`, `NEXT_PUBLIC_` не басқа public префикс қолданылмайды. DB паролі Vercel қолданбасына керек емес.

Publishable key құпия әкімшілік кілт емес: ол браузерге әдейі беріледі. Барлық admin кілттер серверде қалады. Қазіргі қорғалған ортаның Production кілттерін staging мәндерімен ауыстырмаңыз.

1. Төрт branch-specific Preview мәнін сақтаңыз. Preview айнымалыларының ішінде осы branch үшін Production мәні қалып қоймағанын тексеріңіз.
2. Deployments → Create Deployment арқылы PR тармағын таңдаңыз немесе сол тармақтың Preview deployment-ін **Redeploy** жасаңыз. Орта **Preview** екенін тексеріңіз. Promote to Production, main deployment немесе production domain қолданылмайды.
3. Бұрынғы deployment жаңа environment мәндерін алмайды: міндетті түрде жаңасын құрастырыңыз. Бұл repo `vercel.json` арқылы сервер функцияларын және нақты static allowlist-ті жариялайды; оны жай static-hosting ретінде жарияламаңыз.
4. `/api/config` ашыңыз. Оның `url` өрісі staging URL-мен сәйкес, жауабында тек `url` және `publishableKey` болуы керек. Мұнда service_role, DB password және дұрыс жауаптар жоқ.
5. Preview guard `VERCEL_ENV=preview` кезінде staging URL жоқ, сәйкес емес не белгілі Production ref-іне тең болса, `/api/config`, `/api/learning`, `/api/students` үшін **503** береді. Supabase-ке сұрау жіберілмейді. Бұл қате шықса guard-ты өшірмей, төрт айнымалыны түзетіп Redeploy жасаңыз.
6. Guard қолданба API-ін қорғайды, бірақ барлық сыртқы инфрақұрылым баптауын дәлелдемейді. `/api/config` origin және Preview deployment environment/branch-ін бәрібір тексеріңіз. Ескі Preview-дің «Ready» күйі staging оқшау екенін білдірмейді.
7. Supabase **staging** Authentication → URL Configuration ішінде Preview origin-ін Site URL/қажетті redirect allowlist-ке енгізіңіз. Production Auth баптауларын өзгертпеңіз. Тек қажет Preview origin-дерін рұқсат етіңіз.
8. Vercel Deployment Protection қосулы болса, қолмен тексеруді авторизацияланған браузермен орындаңыз. Автотестке қорғалған қолжетімділік қажет; ол жетпесе 401/403-ті тест өтті деп қабылдамаңыз және сайтты осы үшін ашық қылмаңыз.

## 4. Нақты қабылдау сынағы

Мұнда тек synthetic мұғалім мен жаңа synthetic оқушылар қолданылады. Production дерегін импорттамаңыз.

- Мұғалім кіреді, екі жаңа оқушы тіркейді, екеуі жеке парольмен кіреді. Refresh/қайта кіруден кейін нәтижелер сақталады.
- 19 бөлім ашылады; әрқайсысында теория және 2 B + 10 C. Python, Excel, IP, логика, SQL, санау жүйелерінен кемінде бір күрделі есеп орындалады.
- Бос/жарамсыз жауапта шешім ашылмайды. Дұрыс және қате жауаптан кейін ғана шешім/түсіндірме шығады; қате жауапта талдау бар.
- DevTools → Network: workspace/tasks ішінде `answer`, `steps`, `explanation`, `error_feedback`, `mistakes` жоқ. Grade response-та тек жіберілген тапсырманың шешімі келеді. Теориядағы бөлек оқыту мысалдары ашық болуы қалыпты.
- Оқушы A-ның JWT-імен B нәтижесіне GET жасағанда B жолдары келмейді. Attempt-ке жалған `correct=true` INSERT/UPDATE және `unt_teachers` INSERT өтпейді.
- Оқушы өз `profiles.role` өрісін `teacher` етуге тырысқанда рұқсат берілмейді; профильді INSERT/UPSERT арқылы алмастыру да өтпейді. Клиент metadata-дағы рөлге сенім артылмайды.
- Оқушы `/api/students` POST-ына `role:teacher` жіберсе де 403 алады; JWT жоқ болса 401. Аккаунт жасалмайды.
- Supabase public `/auth/v1/signup` сұрауы synthetic email үшін қабылданбайды. `signInAnonymously` өшірулі. Бұл баптауларды тек staging-де сынаңыз; дұрыс HTTP статусымен қатар аккаунттың жасалмағанын Users тізімінен тексеріңіз.
- `unt_private`-ті Data API арқылы оқу өтпейді. `.env`, `/ops/backup-inventory.sql`, `/scripts/curriculum/reviewed.cjs`, `/supabase/migrations/202610180005_quality_review.sql`, `/api/_lib/environment.cjs`, `/docs/BACKUP.md` файлдары site URL-інде 403/404 береді.
- Мұғалім тек өзіне байланыстырылған нәтижелерді көреді. Қазіргі кабинет студенттерді байланыстыру үшін ортақ roster көрсете алады: бұл көп ұйымға толық оқшауланған SaaS емес. Бірнеше ұйым керек болса, бөлек ownership моделі қажет.
- Компьютер және 390 px телефон көрінісінде теория, өріс, «Тексеру», нәтижелер кестесі және шығу жұмыс істейді. ҚМЖ және бұрынғы жергілікті нәтижелер өшпейді.
- Қате байланыс кезінде пароль, service_role, upstream payload немесе stack trace көрсетілмейді. `/api/config` және API нәтижелерінде `Cache-Control: no-store` бар.

Қорғалған жергілікті ортада `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_PUBLISHABLE_KEY`, `STAGING_PREVIEW_URL`, `STAGING_TEACHER_EMAIL`, `STAGING_TEACHER_PASSWORD` берілсе, `npm run test:staging` автоматты hosted smoke орындайды. Мәндерді репозиторийге не чатқа қоспаңыз. Ол synthetic аккаунттар мен нәтижелер **жазады**, сондықтан тек бөлек staging-де орындалады; Production хосты мен Preview→DB сәйкестігі тексеріледі. Тест аккаунттарын жоймайды, task visibility-ді `finally` арқылы қайтарады. Бұл smoke қолмен қаралатын барлық Auth provider/Storage/backup шартын алмастырмайды.

## 5. Production-ға көшуге дейін

[READINESS.md](READINESS.md) кестесіндегі backup, restore және hosted қабылдау жолдары нақты дәлелмен аяқталуы керек. Ескі `profiles` RLS/trigger аудиті және қажет қауіпсіздік өзгерісі бөлек review жасалады; staging bootstrap Production-да орындалмайды.

Пайдаланушының **бөлек нақты растауынсыз** merge, Production миграциясы, Auth баптауын өзгерту, Promote немесе production deployment жасалмайды. Rollback үшін ескі Vercel deployment сақталады; DB кестелері кері қайту үшін жойылмайды.

Ресми құжаттар: [Supabase Auth configuration](https://supabase.com/docs/guides/auth/general-configuration), [Vercel environment scopes және branch variables](https://vercel.com/docs/environment-variables), [Vercel Git deployments](https://vercel.com/docs/git).
