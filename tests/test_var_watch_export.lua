-- Local text export rules, no game API.
local here=arg[0]:match('^(.*)[/\\]') or '.'
local E=dofile(here..'/../var-watch/export.lua')
local checks=0
local function check(ok,label) assert(ok,label);checks=checks+1 end
local parts,info=E.build('catalogue',{B={kind='VarPlayer',id=-4,rawValue='2',value='2 derived',changes=3,after='a\tb\nc'},A={}}, {}, {})
local joined=table.concat(parts)
check(info.rows==2 and info.bytes==#joined and info.parts==#parts,'metadata agrees with complete text')
check(joined:find('\nA\t',1,true) and joined:find('\nA\t',1,true)<joined:find('\nB\t',1,true),'deterministic order')
check(joined:find('B\tVarPlayer\t-4\t2\t2 derived\t3\ta\\tb\\nc\n',1,true),'raw value, display label and escaped action stay separate')
parts,info=E.build('abilities',{}, {['2']='Label two',['1']='Label one'}, {['2']='DEFENCE_RAW'})
check(info.rows==2 and table.concat(parts):find('1\tLabel one\t\n2\tLabel two\tDEFENCE_RAW',1,true),'legacy ability label exports with empty unknown stem')
parts,info=E.build('catalogue',{A={rawValue=string.rep('é',40000)}}, {}, {})
check(#parts>1,'large export is split into bounded pieces')
for _,part in ipairs(parts) do check(#part<=32768,'saved piece stays under32KiB') end
check(table.concat(parts):find(string.rep('é',40000),1,true),'chunking does not lose text')
if utf8 then for _,part in ipairs(parts) do check(utf8.len(part)~=nil,'each saved piece is valid UTF-8') end end
parts,info=E.build('catalogue',{A={value=string.rep('x',8*1024*1024)}}, {}, {})
check(parts==nil and info:find('over 8 MB',1,true),'oversized export fails explicitly, without truncation')
print('Var Watch export: '..checks..' checks passed ('.._VERSION..')')
