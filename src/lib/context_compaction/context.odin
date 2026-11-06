// A derived view only: callers retain and authorize original source records.
package context_compaction

import "core:strings"

VERSION :: 1
MAX_LINES :: 60
MAX_BYTES :: 16384
MAX_LINE_BYTES :: 512

// Flatten embedded newlines before counting; never split a UTF-8 code point.
line :: proc(raw:string, limit:int=MAX_LINE_BYTES) -> string {
    clean:=strings.join(strings.fields(raw,context.temp_allocator)," ",context.temp_allocator)
    if len(clean)<=limit do return clean
    // Hub projections never split an encrypted token. Only the Bridge can
    // decrypt and compact its prose; the intact original stays fetchable.
    if token:=strings.index(clean,"vault:v2:");token>=0 {
        prefix:=clean[:min(token,80)]
        return strings.concatenate({prefix,"[encrypted source exceeds preview; fetch original]"},context.temp_allocator)
    }
    end:=max(0,limit-3)
    for end>0 && clean[end]&0xc0==0x80 {end-=1}
    return strings.concatenate({clean[:end],"..."},context.temp_allocator)
}

// Header/footer reserve provenance and retrieval even when every source is huge.
// Input is in priority order, recent lessons first. Dedup does not delete sources.
project :: proc(header,footer:string,items:[]string) -> string {
    out:=make([dynamic]string,context.temp_allocator)
    seen:=make(map[string]bool,context.temp_allocator)
    append(&out,line(header))
    tail:=line(footer)
    bytes:=len(out[0])+len(tail)+1
    for item in items {
        if strings.trim_space(item)=="" || seen[item] do continue
        seen[item]=true
        text:=line(item)
        if len(out)>=MAX_LINES-1 || bytes+len(text)+1>MAX_BYTES do continue
        append(&out,text)
        bytes+=len(text)+1
    }
    append(&out,tail)
    return strings.join(out[:],"\n",context.temp_allocator)
}
