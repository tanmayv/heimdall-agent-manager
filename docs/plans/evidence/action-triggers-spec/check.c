// Local check for spec S1 (plan v7 section 10): does nats.c 3.13 + nats-server 2.14.7
// give us work-queue retention, MaxAckPending, delayed nak, in-progress and term,
// both through natsMsg_* and through a plain publish to the stored reply subject?
#include <nats/nats.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

static natsConnection *nc;
static jsCtx *js;
static int failures;

#define CHECK(cond, ...) do { if (cond) { printf("PASS  "); } else { printf("FAIL  "); failures++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static uint64_t stream_msgs(const char *stream) {
    jsStreamInfo *si = NULL; jsErrCode e = 0;
    uint64_t n = (uint64_t)-1;
    if (js_GetStreamInfo(&si, js, stream, NULL, &e) == NATS_OK) n = si->State.Msgs;
    jsStreamInfo_Destroy(si);
    return n;
}
static natsStatus pub(const char *subj, const char *body) {
    jsPubAck *pa = NULL; jsErrCode e = 0;
    natsStatus s = js_Publish(&pa, js, subj, body, (int)strlen(body), NULL, &e);
    jsPubAck_Destroy(pa);
    return s;
}
// Fetch at most one message; returns NULL on timeout. meta_delivered gets NumDelivered.
static natsMsg *fetch1(natsSubscription *sub, int64_t timeout_ms, uint64_t *delivered) {
    natsMsgList list; memset(&list, 0, sizeof(list)); jsErrCode e = 0;
    natsStatus s = natsSubscription_Fetch(&list, sub, 1, timeout_ms, &e);
    if (s != NATS_OK || list.Count == 0) { natsMsgList_Destroy(&list); return NULL; }
    natsMsg *m = list.Msgs[0]; list.Msgs[0] = NULL;
    natsMsgList_Destroy(&list);
    if (delivered) { jsMsgMetaData *md = NULL; if (natsMsg_GetMetaData(&md, m) == NATS_OK) *delivered = md->NumDelivered; jsMsgMetaData_Destroy(md); }
    return m;
}
static natsStatus add_consumer(const char *stream, const char *durable, const char *filter, int64_t ack_wait_ns, int64_t max_deliver, int64_t max_ack_pending) {
    jsConsumerInfo *ci = NULL; jsConsumerConfig cfg; jsErrCode e = 0;
    jsConsumerConfig_Init(&cfg);
    cfg.Durable = durable; cfg.AckPolicy = js_AckExplicit; cfg.DeliverPolicy = js_DeliverAll;
    cfg.AckWait = ack_wait_ns; cfg.MaxDeliver = max_deliver; cfg.MaxAckPending = max_ack_pending;
    cfg.FilterSubject = filter;
    natsStatus s = js_AddConsumer(&ci, js, stream, &cfg, NULL, &e);
    if (s != NATS_OK) printf("      add_consumer %s: status %d js %d\n", durable, s, (int)e);
    jsConsumerInfo_Destroy(ci);
    return s;
}
static natsSubscription *bind(const char *stream, const char *durable) {
    natsSubscription *sub = NULL; jsSubOptions so; jsErrCode e = 0;
    jsSubOptions_Init(&so); so.Stream = stream; so.Consumer = durable;
    js_PullSubscribe(&sub, js, NULL, NULL, NULL, &so, &e);
    return sub;
}

int main(int argc, char **argv) {
    const char *url = argc > 1 ? argv[1] : "nats://127.0.0.1:4222";
    natsStatus s = natsConnection_ConnectTo(&nc, url);
    if (s == NATS_OK) s = natsConnection_JetStream(&js, nc, NULL);
    if (s != NATS_OK) { printf("connect failed %d\n", s); return 2; }
    printf("client %s\n", nats_GetVersion());

    // 1. Work-queue stream.
    jsStreamConfig sc; jsStreamInfo *si = NULL; jsErrCode e = 0;
    jsStreamConfig_Init(&sc);
    const char *subjects[] = {"dlv.>"};
    sc.Name = "HEIM_DELIVER"; sc.Subjects = subjects; sc.SubjectsLen = 1;
    sc.Storage = js_FileStorage; sc.Retention = js_WorkQueuePolicy;
    sc.MaxAge = 24LL * 3600 * 1000000000LL; sc.Duplicates = 120LL * 1000000000LL; sc.Replicas = 1;
    s = js_AddStream(&si, js, &sc, NULL, &e);
    CHECK(s == NATS_OK && si && si->Config->Retention == js_WorkQueuePolicy, "1  stream with js_WorkQueuePolicy created (status %d js %d)", s, (int)e);
    jsStreamInfo_Destroy(si);

    // 2. Two per-bridge consumers with disjoint filters, MaxAckPending 16.
    s = add_consumer("HEIM_DELIVER", "brg_b1", "dlv.*.b1.>", 2000000000LL, 3, 16);
    natsStatus s2 = add_consumer("HEIM_DELIVER", "brg_b2", "dlv.*.b2.>", 2000000000LL, 3, 16);
    CHECK(s == NATS_OK && s2 == NATS_OK, "2  two consumers with disjoint filters coexist on the work-queue stream");
    // 2b. Overlapping filter is refused on a work-queue stream.
    natsStatus s3 = add_consumer("HEIM_DELIVER", "brg_overlap", "dlv.>", 2000000000LL, 3, 16);
    CHECK(s3 != NATS_OK, "2b an overlapping filter is refused (expected error above)");
    jsConsumerInfo *ci = NULL;
    s = js_GetConsumerInfo(&ci, js, "HEIM_DELIVER", "brg_b1", NULL, &e);
    CHECK(s == NATS_OK && ci->Config->MaxAckPending == 16, "2c MaxAckPending read back as %" PRId64, ci ? ci->Config->MaxAckPending : -1);
    jsConsumerInfo_Destroy(ci);

    natsSubscription *b1 = bind("HEIM_DELIVER", "brg_b1");
    natsSubscription *b2 = bind("HEIM_DELIVER", "brg_b2");
    natsSubscription *adv = NULL;
    natsConnection_SubscribeSync(&adv, nc, "$JS.EVENT.ADVISORY.CONSUMER.MAX_DELIVERIES.HEIM_DELIVER.*");
    natsSubscription *advterm = NULL;
    natsConnection_SubscribeSync(&advterm, nc, "$JS.EVENT.ADVISORY.CONSUMER.MSG_TERMINATED.HEIM_DELIVER.*");

    // 3. Ack removes the message from the stream; the other bridge never sees it.
    pub("dlv.o1.b1.prompt", "m-ack");
    uint64_t nd = 0;
    natsMsg *m = fetch1(b2, 500, &nd);
    CHECK(m == NULL, "3a consumer b2 does not receive a b1 message");
    m = fetch1(b1, 1000, &nd);
    CHECK(m != NULL && nd == 1, "3b consumer b1 receives it, NumDelivered %" PRIu64, nd);
    s = natsMsg_AckSync(m, NULL, &e); natsMsg_Destroy(m);
    CHECK(s == NATS_OK && stream_msgs("HEIM_DELIVER") == 0, "3c after ack the stream holds %" PRIu64 " messages", stream_msgs("HEIM_DELIVER"));

    // 4. Delayed nak through natsMsg_NakWithDelay: not before the delay, yes after.
    pub("dlv.o1.b1.prompt", "m-nak");
    m = fetch1(b1, 1000, &nd);
    s = natsMsg_NakWithDelay(m, 3000, NULL); natsMsg_Destroy(m);   // delay in ms
    natsConnection_Flush(nc);
    int64_t t0 = nats_Now();
    m = fetch1(b1, 2000, &nd);
    CHECK(s == NATS_OK && m == NULL, "4a natsMsg_NakWithDelay(3000 ms): nothing redelivered in the first 2 s");
    if (m) natsMsg_Destroy(m);
    m = fetch1(b1, 3000, &nd);
    CHECK(m != NULL && nd == 2, "4b redelivered after %" PRId64 " ms with NumDelivered %" PRIu64, nats_Now() - t0, nd);

    // 5. Delayed nak by a plain publish to the stored reply subject (no message handle).
    char reply[512] = {0};
    if (m) { strncpy(reply, natsMsg_GetReply(m), sizeof(reply) - 1); natsMsg_Destroy(m); }
    printf("      reply subject: %s\n", reply);
    s = natsConnection_PublishString(nc, reply, "-NAK {\"delay\": 3000000000}");   // delay in ns
    natsConnection_Flush(nc);
    t0 = nats_Now();
    m = fetch1(b1, 2000, &nd);
    CHECK(s == NATS_OK && m == NULL, "5a '-NAK {\"delay\": ns}' to the reply subject: nothing in the first 2 s");
    if (m) natsMsg_Destroy(m);
    m = fetch1(b1, 3000, &nd);
    CHECK(m != NULL && nd == 3, "5b redelivered after %" PRId64 " ms with NumDelivered %" PRIu64 " (= MaxDeliver)", nats_Now() - t0, nd);

    // 6. In-progress by reply subject extends AckWait (2 s).
    if (m) { strncpy(reply, natsMsg_GetReply(m), sizeof(reply) - 1); natsMsg_Destroy(m); }
    nats_Sleep(1500);
    s = natsConnection_PublishString(nc, reply, "+WPI"); natsConnection_Flush(nc);
    nats_Sleep(1500);   // 3.0 s after delivery: past the original AckWait, inside the extended one
    natsMsg *advm = NULL;
    natsStatus as = natsSubscription_NextMsg(&advm, adv, 100);
    CHECK(s == NATS_OK && as == NATS_TIMEOUT, "6  '+WPI' at 1.5 s: no max-deliveries advisory at 3.0 s (AckWait was extended)");
    if (advm) natsMsg_Destroy(advm);

    // 7. Let the last attempt time out: MaxDeliver exhausted. Is there an advisory with no pull waiting?
    advm = NULL;
    as = natsSubscription_NextMsg(&advm, adv, 4000);
    printf("INFO  7a advisory with NO pull request waiting, 4 s after the final AckWait: %s\n", as == NATS_OK ? "received" : "not received");
    if (advm) natsMsg_Destroy(advm);
    m = fetch1(b1, 2500, &nd);
    CHECK(m == NULL, "7b the exhausted message is not delivered again");
    if (m) natsMsg_Destroy(m);
    advm = NULL;
    as = natsSubscription_NextMsg(&advm, adv, 1000);
    CHECK(as == NATS_OK, "7d max-deliveries advisory received once a pull request was waiting");
    if (advm) { printf("      advisory: %.*s\n", natsMsg_GetDataLength(advm), natsMsg_GetData(advm)); natsMsg_Destroy(advm); }
    printf("INFO  7c after MaxDeliver exhaustion the work-queue stream still holds %" PRIu64 " message(s)\n", stream_msgs("HEIM_DELIVER"));

    // 8. Term by reply subject: no redelivery; removed from a work-queue stream?
    pub("dlv.o1.b1.prompt", "m-term");
    m = fetch1(b1, 1000, &nd);
    if (m) { strncpy(reply, natsMsg_GetReply(m), sizeof(reply) - 1); natsMsg_Destroy(m); }
    uint64_t before = stream_msgs("HEIM_DELIVER");
    s = natsConnection_PublishString(nc, reply, "+TERM"); natsConnection_Flush(nc);
    m = fetch1(b1, 3000, &nd);
    CHECK(s == NATS_OK && m == NULL, "8a '+TERM' to the reply subject: not redelivered within 3 s (AckWait 2 s)");
    if (m) natsMsg_Destroy(m);
    printf("INFO  8b stream messages before term %" PRIu64 ", after term %" PRIu64 "\n", before, stream_msgs("HEIM_DELIVER"));
    advm = NULL; as = natsSubscription_NextMsg(&advm, advterm, 500);
    printf("INFO  8c MSG_TERMINATED advisory %s\n", as == NATS_OK ? "received" : "not received");
    if (advm) natsMsg_Destroy(advm);

    // 9. Ack by reply subject with request/reply (what ham_nats_ack_reply does today).
    pub("dlv.o1.b1.prompt", "m-ack2");
    m = fetch1(b1, 1000, &nd);
    if (m) { strncpy(reply, natsMsg_GetReply(m), sizeof(reply) - 1); natsMsg_Destroy(m); }
    before = stream_msgs("HEIM_DELIVER");
    natsMsg *resp = NULL;
    s = natsConnection_Request(&resp, nc, reply, "+ACK", 4, 1000); natsMsg_Destroy(resp);
    CHECK(s == NATS_OK && stream_msgs("HEIM_DELIVER") == before - 1, "9  '+ACK' request to the reply subject removes the message (%" PRIu64 " -> %" PRIu64 ")", before, stream_msgs("HEIM_DELIVER"));

    // 10. MaxAckPending: with 16 unacked, the 17th is held back.
    for (int i = 0; i < 20; i++) pub("dlv.o1.b2.notice", "m-flow");
    natsMsgList list; memset(&list, 0, sizeof(list));
    s = natsSubscription_Fetch(&list, b2, 20, 1500, &e);
    CHECK(list.Count == 16, "10 fetch of 20 with MaxAckPending 16 returned %d", list.Count);
    natsMsgList_Destroy(&list);

    // 11. Duplicate window: same Nats-Msg-Id twice -> second is a duplicate.
    jsPubOptions po; jsPubOptions_Init(&po); po.MsgId = "dlv_same";
    jsPubAck *pa = NULL; js_Publish(&pa, js, "dlv.o1.b1.prompt", "a", 1, &po, &e); jsPubAck_Destroy(pa);
    pa = NULL; s = js_Publish(&pa, js, "dlv.o1.b1.prompt", "a", 1, &po, &e);
    CHECK(s == NATS_OK && pa && pa->Duplicate, "11 repeated Nats-Msg-Id inside the window is reported duplicate");
    jsPubAck_Destroy(pa);

    // 12. Deleting a consumer and purging its subject filter (bridge deleted).
    s = js_DeleteConsumer(js, "HEIM_DELIVER", "brg_b2", NULL, &e);
    jsOptions jo; jsOptions_Init(&jo); jo.Stream.Purge.Subject = "dlv.*.b2.>";
    natsStatus ps = js_PurgeStream(js, "HEIM_DELIVER", &jo, &e);
    CHECK(s == NATS_OK && ps == NATS_OK, "12 consumer deleted and its subjects purged (purge status %d js %d)", ps, (int)e);


    // 13. Does a message nak'd with a delay keep counting against MaxAckPending?
    add_consumer("HEIM_DELIVER", "brg_b3", "dlv.*.b3.>", 30000000000LL, 8, 2);
    natsSubscription *b3 = bind("HEIM_DELIVER", "brg_b3");
    pub("dlv.o1.b3.prompt", "busy-1"); pub("dlv.o1.b3.prompt", "busy-2"); pub("dlv.o1.b3.notice", "other-3");
    natsMsg *m1 = fetch1(b3, 1000, &nd), *m2 = fetch1(b3, 1000, &nd);
    CHECK(m1 && m2, "13a two messages fetched (MaxAckPending 2)");
    if (m1) { natsMsg_NakWithDelay(m1, 8000, NULL); natsMsg_Destroy(m1); }
    if (m2) { natsMsg_NakWithDelay(m2, 8000, NULL); natsMsg_Destroy(m2); }
    natsConnection_Flush(nc);
    ci = NULL; js_GetConsumerInfo(&ci, js, "HEIM_DELIVER", "brg_b3", NULL, &e);
    printf("INFO  13b after two delayed naks (8 s): NumAckPending %" PRId64 ", NumRedelivered %" PRId64 ", NumPending %" PRIu64 "\n", ci ? ci->NumAckPending : -1, ci ? ci->NumRedelivered : -1, ci ? ci->NumPending : 0);
    jsConsumerInfo_Destroy(ci);
    m = fetch1(b3, 3000, &nd);
    printf("INFO  13c third message while both naks are still delayed: %s%s\n", m ? "DELIVERED: " : "HELD BACK", m ? natsMsg_GetData(m) : "");
    if (m) { natsMsg_AckSync(m, NULL, &e); natsMsg_Destroy(m); }
    natsSubscription_Destroy(b3);

    natsSubscription_Destroy(b1); natsSubscription_Destroy(b2); natsSubscription_Destroy(adv); natsSubscription_Destroy(advterm);
    jsCtx_Destroy(js); natsConnection_Destroy(nc); nats_Close();
    printf("failures: %d\n", failures);
    return failures ? 1 : 0;
}
