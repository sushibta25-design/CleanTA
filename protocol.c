#include "../CTProtocol.h"
#include <assert.h>
int main(void) {
    assert(CTOutcome(0,42)==CTOutcomeUnknown);
    assert(CTOutcome(CTMakeSample(-1,0,2),42)==CTOutcomeOldExited);
    assert(CTOutcome(CTMakeSample(-1,2,2),42)==CTOutcomeUnknown);
    assert(CTOutcome(CTMakeSample(43,0,1),42)==CTOutcomeNewProcess);
    assert(CTOutcome(CTMakeSample(42,1,1),42)==CTOutcomeUnknown);
    assert(CTOutcome(CTMakeSample(0,0,2),42)==CTOutcomeStopped);

    assert(CTSampleStopped(CTMakeSample(0,0,2)));
    assert(CTSampleStopped(CTMakeSample(42,0,0))); // stale API PID, absent in kernel
    assert(!CTSampleStopped(CTMakeSample(0,1,2))); // API says zero, old PID exists
    assert(!CTSampleStopped(CTMakeSample(43,0,1))); // restarted with new PID
    assert(!CTSampleStopped(CTMakeSample(-1,0,2))); // failed lookup is not success
    assert(!CTSampleStopped(CTMakeSample(42,2,2))); // permission/lookup ambiguity
    assert(!CTSampleStopped(0)); // missing sample
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
