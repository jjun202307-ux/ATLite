#ifndef ATL_REGISTRATION_STATE_H
#define ATL_REGISTRATION_STATE_H

typedef enum {
    ATL_REG_PENDING, ATL_REG_PREPARING, ATL_REG_READY, ATL_REG_SUBMITTING,
    ATL_REG_WAIT_CODE, ATL_REG_DONE, ATL_REG_ERROR, ATL_REG_REVIEW
} ATLRegState;
typedef enum {
    ATL_REG_CLAIM, ATL_REG_FIELDS_READY, ATL_REG_BEGIN_SUBMIT,
    ATL_REG_VERIFICATION_SEEN, ATL_REG_SUCCESS_CONFIRMED, ATL_REG_INTERRUPTED,
    ATL_REG_FAILED
} ATLRegEvent;

/* Pure transition table. Persistence and side effects must happen under the
   caller's lock. SUBMITTING must be durable before dispatching any tap. */
static inline int ATLRegStep(ATLRegState state, ATLRegEvent event, ATLRegState *next) {
    if (!next) return 0;
    if (event == ATL_REG_INTERRUPTED && (state == ATL_REG_PREPARING || state == ATL_REG_READY || state == ATL_REG_SUBMITTING || state == ATL_REG_WAIT_CODE)) {
        *next = ATL_REG_REVIEW; return 1;
    }
    if (event == ATL_REG_FAILED && (state == ATL_REG_PREPARING || state == ATL_REG_READY)) {
        *next = ATL_REG_ERROR; return 1;
    }
    if (event == ATL_REG_FAILED && (state == ATL_REG_SUBMITTING || state == ATL_REG_WAIT_CODE)) {
        *next = ATL_REG_REVIEW; return 1;
    }
    if (state == ATL_REG_PENDING && event == ATL_REG_CLAIM) *next = ATL_REG_PREPARING;
    else if (state == ATL_REG_PREPARING && event == ATL_REG_FIELDS_READY) *next = ATL_REG_READY;
    else if (state == ATL_REG_READY && event == ATL_REG_BEGIN_SUBMIT) *next = ATL_REG_SUBMITTING;
    else if (state == ATL_REG_SUBMITTING && event == ATL_REG_VERIFICATION_SEEN) *next = ATL_REG_WAIT_CODE;
    else if (state == ATL_REG_WAIT_CODE && event == ATL_REG_SUCCESS_CONFIRMED) *next = ATL_REG_DONE;
    else return 0;
    return 1;
}
#endif
