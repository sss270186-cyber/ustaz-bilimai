const {execFileSync}=require('node:child_process');const {tasks}=require('./curriculum.cjs');
process.stdout.write(execFileSync('python',['tests/verify-programs.py'],{input:JSON.stringify(tasks),encoding:'utf8'}));
