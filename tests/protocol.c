#include "../CTProtocol.h"
#include <assert.h>
int main(void) {
    int pids[] = {2,42,65535,2147483647};
    for (unsigned i=0;i<sizeof(pids)/sizeof(*pids);i++) {
        uint64_t key=CTKey("com.example.player",pids[i]);
        assert(CTValidKey(key)); assert((uint32_t)(key>>2)==(uint32_t)pids[i]);
        assert(CTKey("com.example.other",pids[i])!=key);
        for(unsigned status=1;status<=3;status++) {
            assert(!CTValidKey(key|status)); assert(((key|status)&~UINT64_C(3))==key);
        }
    }
    assert(!CTKey(0,42)); assert(!CTKey("",42)); assert(!CTKey("x",1));
    assert(!CTKey("x",-1)); assert(!CTValidKey(0));
    assert(!CTValidKey(UINT64_C(0xffffffff)<<2));
    assert(CTKey("x",42)!=CTKey("x",43));
}
