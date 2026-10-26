import {sqliteTable,text,integer,index,primaryKey} from 'drizzle-orm/sqlite-core';
export const users=sqliteTable('users',{
 id:text('id').primaryKey(),username:text('username').notNull().unique(),email:text('email').unique(),sitesId:text('sites_id').unique(),
 fullName:text('full_name').notNull(),className:text('class_name').notNull(),role:text('role').notNull(),teacherId:text('teacher_id'),
 passwordHash:text('password_hash'),passwordSalt:text('password_salt'),active:integer('active').notNull().default(1),createdAt:text('created_at').notNull()
});
export const sessions=sqliteTable('sessions',{
 tokenHash:text('token_hash').primaryKey(),userId:text('user_id').notNull().references(()=>users.id),expiresAt:integer('expires_at').notNull(),revoked:integer('revoked').notNull().default(0)
},t=>[index('sessions_user').on(t.userId)]);
export const attempts=sqliteTable('attempts',{
 id:text('id').primaryKey(),studentId:text('student_id').notNull().references(()=>users.id),taskId:text('task_id').notNull(),taskRevision:integer('task_revision').notNull(),
 submittedAnswer:text('submitted_answer').notNull(),correct:integer('correct').notNull(),createdAt:text('created_at').notNull(),taskSnapshot:text('task_snapshot').notNull()
},t=>[index('attempt_student_time').on(t.studentId,t.createdAt)]);
export const taskVersions=sqliteTable('task_versions',{
 teacherId:text('teacher_id').notNull().references(()=>users.id),taskId:text('task_id').notNull(),revision:integer('revision').notNull(),content:text('content').notNull(),createdAt:text('created_at').notNull()
},t=>[primaryKey({columns:[t.teacherId,t.taskId,t.revision]})]);
export const taskState=sqliteTable('task_state',{
 teacherId:text('teacher_id').notNull().references(()=>users.id),taskId:text('task_id').notNull(),active:integer('active').notNull().default(1)
},t=>[primaryKey({columns:[t.teacherId,t.taskId]})]);
export const loginEvents=sqliteTable('login_events',{
 id:text('id').primaryKey(),bucket:text('bucket').notNull(),createdAt:integer('created_at').notNull()
},t=>[index('login_bucket_time').on(t.bucket,t.createdAt)]);
export const audit=sqliteTable('audit_log',{
 id:text('id').primaryKey(),actorId:text('actor_id').notNull(),action:text('action').notNull(),subjectId:text('subject_id').notNull(),createdAt:text('created_at').notNull()
});
