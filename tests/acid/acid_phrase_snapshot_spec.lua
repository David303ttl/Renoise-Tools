dofile('tests/bootstrap.lua')('acid')
local ownership=require('writers.phrase_ownership')
local fixture=dofile('tests/acid/complete_phrase_fixture.lua')
local phrase=fixture()
phrase.mapping={key_tracking=3,base_note=43,note_range={36,47},looping=true,loop_start=2,loop_end=14}
phrase.script.paragraphs={'return pattern {}','-- sentinel'}
phrase.script.parameters={{name='sentinel',value=23}}
local captured=assert(ownership.snapshot(phrase))
assert(#captured.lines==512 and #captured.lines[512].notes==12 and #captured.lines[512].effects==8)
assert(captured.mapping.note_range[2]==47 and captured.script.parameters[1].value==23)
local copied=assert(ownership.copy_snapshot(captured))
assert(ownership.compare(captured,copied))
phrase.lines[512].note_columns[12].effect_amount_value=71
phrase.mapping.note_range[1]=37
phrase.script.paragraphs[1]='changed'
phrase.script.parameters[1].value=99
phrase.column_names[12]='changed'
assert(captured.lines[512].notes[12].effect_amount_value==0 and captured.mapping.note_range[1]==36)
assert(captured.script.paragraphs[1]=='return pattern {}' and captured.script.parameters[1].value==23)
assert(captured.columns[12].name=='column 12')
copied.mapping.note_range[1]=12
assert(captured.mapping.note_range[1]==36)
local function changes(path)
  local changed=assert(ownership.copy_snapshot(captured));local parent=changed
  for index=1,#path-1 do parent=parent[path[index]]end
  local key=path[#path];local old=parent[key]
  if type(old)=='boolean'then parent[key]=not old elseif type(old)=='number'then parent[key]=old+1 else parent[key]=old..'!'end
  local equal,reason=ownership.compare(captured,changed)
  assert(not equal and reason:find('Phrase differs',1,true))
  return changed
end
for key in pairs(captured.properties)do changes({'properties',key})end
for _,key in ipairs({'name','muted'})do changes({'columns',12,key})end
for key in pairs(captured.mapping)do if key~='note_range'then changes({'mapping',key})end end
changes({'mapping','note_range',1});changes({'mapping','note_range',2})
for key in pairs(captured.lines[512].notes[12])do changes({'lines',512,'notes',12,key})end
for key in pairs(captured.lines[512].effects[8])do changes({'lines',512,'effects',8,key})end
changes({'script','paragraphs',2});changes({'script','parameters',1,'name'});changes({'script','parameters',1,'value'})
changes({'script','pending_changes'});changes({'script','editor_visible'})
local renamed=changes({'name'})
assert(ownership.compare(captured,renamed,'name'))
assert(not ownership.compare(captured,changes({'properties','base_note'}),'name'))
assert(ownership.compare(captured,renamed,'generated'))
for _,key in ipairs({'number_of_lines','lpb','shuffle','looping','loop_start','loop_end','playback_mode','key_tracking'})do
 assert(ownership.compare(captured,changes({'properties',key}),'generated'))
end
-- Generated comparison checks preservation; complete output checks constrain all cells.
assert(ownership.compare(captured,changes({'lines',512,'notes',12,'volume_value'}),'generated'))
for _,path in ipairs({{'properties','visible_note_columns'},{'properties','base_note'},{'properties','autoseek'},
 {'mapping','base_note'},{'columns',12,'muted'},{'script','pending_changes'}})do
 assert(not ownership.compare(captured,changes(path),'generated'))
end
assert(not ownership.compare(captured,captured,'unknown'))
local empty=assert(ownership.snapshot(fixture()))
assert(ownership.empty_script(empty))
for _,update in ipairs({function(s)s.paragraphs={' '}end,function(s)s.parameters={{name='p',value=1}}end,
 function(s)s.pending_changes=1 end,function(s)s.editor_visible=false end})do
 local bad=assert(ownership.copy_snapshot(empty));update(bad.script);assert(not ownership.empty_script(bad))
end
local unreadable=fixture();unreadable.lines[512].note_columns[12].delay_value=nil
assert(not ownership.snapshot(unreadable))
unreadable=fixture();unreadable.script=setmetatable({},{__index=function()error('access denied')end})
assert(not ownership.snapshot(unreadable))
unreadable=fixture();unreadable.column_name=function()return nil end
assert(not ownership.snapshot(unreadable))
for _,bad in ipairs({{host=function()end},setmetatable({},{__index=function()end}),{number=0/0}})do
 assert(not ownership.copy_snapshot(bad))
end
local cycle={};cycle.self=cycle;assert(not ownership.copy_snapshot(cycle))


local several=assert(ownership.copy_snapshot(captured));several.name='different';several.properties.lpb=32
local same,reason=ownership.compare(captured,several)
assert(not same and reason=='Phrase differs at name')
local missing=assert(ownership.copy_snapshot(captured));missing.lines[512].effects[8].is_empty=nil
assert(not ownership.compare(captured,missing))
local extra=assert(ownership.copy_snapshot(captured));extra.mapping.extra=1
assert(not ownership.compare(captured,extra))
local function detached(v)
 local kind=type(v)
 assert(kind=='table' or kind=='string' or kind=='number' or kind=='boolean')
 if kind=='table'then assert(getmetatable(v)==nil);for _,item in pairs(v)do detached(item)end end
end
detached(captured)
unreadable=fixture();unreadable.mapping=false;assert(not ownership.snapshot(unreadable))
assert(not ownership.copy_snapshot({host=io.stdin}))

print('ACID complete phrase snapshot and comparison checks passed')
