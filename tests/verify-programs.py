"""Run only repository-authored Python/SQL teaching fixtures, never student input."""
import sys,json,io,contextlib,sqlite3,re,decimal,ipaddress
items=json.load(sys.stdin)
count=0
for t in items:
    if t['topic_id'] in ('python','functions'):
        out=io.StringIO()
        with contextlib.redirect_stdout(out):
            exec(compile(t['code'],t['id'],'exec'),{'__name__':'__main__'})
        actual=out.getvalue().strip()
    elif t['topic_id']=='sql':
        setup,query=t['code'].split('-- Query\n')
        db=sqlite3.connect(':memory:')
        db.executescript(setup)
        rows=db.execute(query).fetchall()
        assert len(rows)==1 and len(rows[0])==1,t['id']
        actual=str(rows[0][0]);db.close()
    else:continue
    if t['answer_format']=='number':assert decimal.Decimal(actual)==decimal.Decimal(t['answer']),(t['id'],actual,t['answer'])
    elif t['answer_format']=='sequence':assert re.split(r'[,;\s]+',actual.lower())==re.split(r'[,;\s]+',t['answer'].lower()),(t['id'],actual,t['answer'])
    else:assert ' '.join(actual.lower().split())==' '.join(t['answer'].lower().split()),(t['id'],actual,t['answer'])
    count+=1
print(f'Executed {count} authored Python/SQL tasks successfully.')
# IPv4/IPv6 answers are checked with Python stdlib independently of JS fixtures.
answers={t['id']:t['answer'] for t in items if t['topic_id']=='ip'}
assert answers['ip-b01']==str(ipaddress.ip_network('192.168.14.77/24',strict=False).network_address)
parent=ipaddress.ip_network('172.19.80.0/20')
second=ipaddress.ip_address(int(parent.network_address)+1024)
assert answers['ip-c01']==str(ipaddress.ip_network(str(second)+'/23'))
addr=ipaddress.ip_address('10.42.8.0')
import math
for h in [134,62,28,2]:
    size=2**math.ceil(math.log2(h+2))
    network=ipaddress.ip_network(str(addr)+'/'+str(32-int(math.log2(size))))
    addr+=size
assert answers['ip-c04']==str(network.broadcast_address-1)
assert answers['ip-c02']==str(ipaddress.ip_network('10.24.37.18/22',strict=False).broadcast_address)
assert answers['ip-c03']==str(ipaddress.ip_network('192.168.5.150/26',strict=False).broadcast_address-1)
assert answers['ip-c07']==str(next(ipaddress.collapse_addresses([ipaddress.ip_network(f'192.168.{i}.0/24') for i in range(32,40)])))
assert answers['ip-c08']==str(ipaddress.ip_address('172.16.8.0')+300)
assert answers['ip-c10']==ipaddress.ip_address('2001:0db8:0000:0000:0020:0000:0000:0001').compressed
print('IP address answers match Python ipaddress.')
