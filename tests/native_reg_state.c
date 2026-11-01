#include <assert.h>
#include "../shared/ATLRegistrationState.h"
int main(void) {
 ATLRegState next;
 assert(ATLRegStep(ATL_REG_PENDING, ATL_REG_CLAIM, &next) && next==ATL_REG_PREPARING);
 assert(ATLRegStep(ATL_REG_PREPARING, ATL_REG_FIELDS_READY, &next) && next==ATL_REG_READY);
 assert(ATLRegStep(ATL_REG_READY, ATL_REG_BEGIN_SUBMIT, &next) && next==ATL_REG_SUBMITTING);
 assert(ATLRegStep(ATL_REG_SUBMITTING, ATL_REG_VERIFICATION_SEEN, &next) && next==ATL_REG_WAIT_CODE);
 assert(!ATLRegStep(ATL_REG_WAIT_CODE, ATL_REG_SUCCESS_CONFIRMED, &next));
 assert(ATLRegStep(ATL_REG_WAIT_CODE, ATL_REG_CODE_STAGED, &next) && next==ATL_REG_CODE_READY);
 assert(ATLRegStep(ATL_REG_CODE_READY, ATL_REG_CLAIM_CODE, &next) && next==ATL_REG_ENTERING_CODE);
 assert(ATLRegStep(ATL_REG_ENTERING_CODE, ATL_REG_SUCCESS_CONFIRMED, &next) && next==ATL_REG_DONE);
 assert(!ATLRegStep(ATL_REG_ENTERING_CODE, ATL_REG_CLAIM_CODE, &next));
 assert(ATLRegStep(ATL_REG_ENTERING_CODE, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 assert(ATLRegStep(ATL_REG_CODE_READY, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 assert(!ATLRegStep(ATL_REG_SUBMITTING, ATL_REG_BEGIN_SUBMIT, &next));
 assert(!ATLRegStep(ATL_REG_PENDING, ATL_REG_SUCCESS_CONFIRMED, &next));
 assert(!ATLRegStep(ATL_REG_DONE, ATL_REG_CLAIM, &next));
 assert(!ATLRegStep(ATL_REG_WAIT_CODE, ATL_REG_BEGIN_SUBMIT, &next));
 assert(ATLRegStep(ATL_REG_SUBMITTING, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 assert(ATLRegStep(ATL_REG_PREPARING, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 assert(ATLRegStep(ATL_REG_READY, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 assert(!ATLRegStep(ATL_REG_REVIEW, ATL_REG_BEGIN_SUBMIT, &next));
 assert(ATLRegStep(ATL_REG_REVIEW, ATL_REG_RESUME_VERIFICATION, &next) && next==ATL_REG_WAIT_CODE);
 assert(ATLRegStep(ATL_REG_WAIT_CODE, ATL_REG_INTERRUPTED, &next) && next==ATL_REG_REVIEW);
 for (int event=ATL_REG_CLAIM; event<=ATL_REG_RESUME_VERIFICATION; ++event) {
   next=ATL_REG_DONE;
   assert(!ATLRegStep(ATL_REG_DONE, (ATLRegEvent)event, &next) && next==ATL_REG_DONE);
   if(event!=ATL_REG_RESUME_VERIFICATION)assert(!ATLRegStep(ATL_REG_REVIEW, (ATLRegEvent)event, &next) && next==ATL_REG_DONE);
 }
 next=ATL_REG_DONE; assert(!ATLRegStep((ATLRegState)999, ATL_REG_CLAIM, &next) && next==ATL_REG_DONE);
 assert(!ATLRegStep(ATL_REG_PENDING, ATL_REG_CLAIM, 0));
 return 0;
}
