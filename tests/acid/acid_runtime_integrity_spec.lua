dofile('tests/bootstrap.lua')('acid')
local helper=dofile('tests/acid/runtime_phrase_fixture.lua')
local integrity=require('runtime.integrity')

-- Metadata uncertainty survives suspension and same-song resume.
do
 local song=select(1,helper.fixture())
 local owner=integrity.new(song,nil)
 local raw=song.tool_data
 local receipt=assert(owner:capture_metadata(raw))
 song.tool_data=(raw or '')..'changed'
 assert(owner:record(receipt))
 assert(owner:state().blocked and owner:state().reason=='ACID cannot safely update this song')
 owner:suspend()
 assert(owner:resume(song,nil))
 assert(owner:state().blocked,'same-song integrity resume discarded metadata evidence')
 assert(song.tool_data~=(raw or ''),'fixture did not retain the uncertain metadata outcome')
end

print('ACID runtime integrity evidence remains fail-closed')
