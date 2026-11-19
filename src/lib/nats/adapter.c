// Private ABI adapter. All nats.c structs and their destruction stay here.
// No callbacks into Odin, including on reconnect/error paths.
#include <nats/nats.h>
#include <stdint.h>
#include <stdlib.h>

typedef struct { natsConnection *nc; jsCtx *js; } ham_nats;
typedef struct { uint64_t messages, first, last; } ham_stream_state;
typedef struct { uint64_t sequence; int duplicate; } ham_pub_ack;
typedef struct { uint64_t stream_sequence, consumer_sequence, num_delivered, num_pending; } ham_metadata;

const char *ham_nats_version(void) { return nats_GetVersion(); }

int ham_nats_connect(ham_nats **out, const char *url, const char *creds,
                     const char *ca, int64_t timeout_ms) {
    *out = NULL;
    natsOptions *opts = NULL;
    ham_nats *h = calloc(1, sizeof(*h));
    if (h == NULL) return NATS_NO_MEMORY;
    natsStatus s = natsOptions_Create(&opts);
    if (s == NATS_OK) s = natsOptions_SetURL(opts, url);
    if (s == NATS_OK) s = natsOptions_SetTimeout(opts, timeout_ms);
    // Fail calls during outages rather than silently queueing non-durable data.
    if (s == NATS_OK) s = natsOptions_SetReconnectBufSize(opts, 0);
    if (s == NATS_OK && creds && *creds)
        s = natsOptions_SetUserCredentialsFromFiles(opts, creds, NULL);
    if (s == NATS_OK && ca && *ca) {
        s = natsOptions_LoadCATrustedCertificates(opts, ca);
        if (s == NATS_OK) s = natsOptions_SetSecure(opts, true);
    }
    if (s == NATS_OK) s = natsConnection_Connect(&h->nc, opts);
    jsOptions jsopts;
    if (s == NATS_OK) s = jsOptions_Init(&jsopts);
    jsopts.Wait = timeout_ms;
    if (s == NATS_OK) s = natsConnection_JetStream(&h->js, h->nc, &jsopts);
    natsOptions_Destroy(opts);
    if (s != NATS_OK) {
        jsCtx_Destroy(h->js);
        natsConnection_Destroy(h->nc);
        free(h);
        return s;
    }
    *out = h;
    return NATS_OK;
}
void ham_nats_destroy(ham_nats *h) {
    if (!h) return;
    jsCtx_Destroy(h->js);
    natsConnection_Destroy(h->nc);
    free(h);
}
int ham_nats_publish(ham_nats *h, const char *subject, const void *data, int len,
                     const char *id, const char **keys, const char **values,
                     int count, ham_pub_ack *out, jsErrCode *err) {
    natsMsg *msg = NULL;
    jsPubAck *ack = NULL;
    natsStatus s = natsMsg_Create(&msg, subject, NULL, data, len);
    for (int i = 0; s == NATS_OK && i < count; i++)
        s = natsMsgHeader_Add(msg, keys[i], values[i]);
    // The explicit id wins over any arbitrary Nats-Msg-Id header.
    if (s == NATS_OK && id && *id) s = natsMsgHeader_Set(msg, "Nats-Msg-Id", id);
    if (s == NATS_OK) s = js_PublishMsg(&ack, h->js, msg, NULL, err);
    if (s == NATS_OK) {
        out->sequence = ack->Sequence;
        out->duplicate = ack->Duplicate;
    }
    jsPubAck_Destroy(ack);
    natsMsg_Destroy(msg);
    return s;
}
int ham_nats_stream(ham_nats *h, int operation, const char *name,
                    const char **subjects, int count, int64_t max_age_ns,
                    int64_t duplicate_ns, int64_t replicas, int rollup, int direct,
                    ham_stream_state *out, jsErrCode *err) {
    jsStreamInfo *info = NULL;
    jsStreamConfig cfg;
    natsStatus s = jsStreamConfig_Init(&cfg);
    if (s != NATS_OK) return s;
    cfg.Name = name;
    cfg.Subjects = subjects;
    cfg.SubjectsLen = count;
    cfg.Storage = js_FileStorage;
    cfg.Retention = js_LimitsPolicy;
    cfg.MaxAge = max_age_ns;
    cfg.Duplicates = duplicate_ns;
    cfg.Replicas = replicas;
    cfg.AllowRollup = rollup != 0;
    cfg.AllowDirect = direct != 0;
    if (operation == 0) s = js_AddStream(&info, h->js, &cfg, NULL, err);
    else if (operation == 1) s = js_UpdateStream(&info, h->js, &cfg, NULL, err);
    else s = js_GetStreamInfo(&info, h->js, name, NULL, err);
    if (s == NATS_OK) {
        out->messages = info->State.Msgs;
        out->first = info->State.FirstSeq;
        out->last = info->State.LastSeq;
    }
    jsStreamInfo_Destroy(info);
    return s;
}
int ham_nats_consumer_add(ham_nats *h, const char *stream, const char *durable,
                          const char **filters, int count, int64_t ack_wait_ns,
                          int64_t max_deliver, jsErrCode *err) {
    jsConsumerInfo *info = NULL;
    jsConsumerConfig cfg;
    natsStatus s = jsConsumerConfig_Init(&cfg);
    if (s != NATS_OK) return s;
    cfg.Durable = durable;
    cfg.AckPolicy = js_AckExplicit;
    cfg.DeliverPolicy = js_DeliverAll;
    cfg.AckWait = ack_wait_ns;
    cfg.MaxDeliver = max_deliver;
    if (count == 1) cfg.FilterSubject = filters[0];
    else { cfg.FilterSubjects = filters; cfg.FilterSubjectsLen = count; }
    s = js_AddConsumer(&info, h->js, stream, &cfg, NULL, err);
    jsConsumerInfo_Destroy(info);
    return s;
}
int ham_nats_consumer_delete(ham_nats *h, const char *stream, const char *name, jsErrCode *err) {
    return js_DeleteConsumer(h->js, stream, name, NULL, err);
}
int ham_nats_pull_bind(natsSubscription **out, ham_nats *h, const char *stream,
                       const char *durable, jsErrCode *err) {
    *out = NULL;
    jsSubOptions opts;
    natsStatus s = jsSubOptions_Init(&opts);
    if (s != NATS_OK) return s;
    opts.Stream = stream;
    opts.Consumer = durable;
    s = js_PullSubscribe(out, h->js, NULL, NULL, NULL, &opts, err);
    if (s != NATS_OK) { natsSubscription_Destroy(*out); *out = NULL; }
    return s;
}
void ham_nats_pull_destroy(natsSubscription *sub) { natsSubscription_Destroy(sub); }

static int ham_nats_fetch_options(natsMsgList **out, natsSubscription *sub, int count,
                                  int64_t timeout, int no_wait, jsErrCode *err) {
    *out = NULL;
    natsMsgList *list = calloc(1, sizeof(*list));
    if (!list) return NATS_NO_MEMORY;
    natsStatus s;
    if (no_wait) {
        jsFetchRequest request;
        s = jsFetchRequest_Init(&request);
        if (s == NATS_OK) {
            request.Batch = count;
            request.Expires = timeout * 1000000;
            request.NoWait = true;
            s = natsSubscription_FetchRequest(list, sub, &request);
        }
        if (s == NATS_NOT_FOUND) s = NATS_TIMEOUT;
    } else {
        s = natsSubscription_Fetch(list, sub, count, timeout, err);
    }
    if (s != NATS_OK) { natsMsgList_Destroy(list); free(list); return s; }
    *out = list;
    return NATS_OK;
}
int ham_nats_fetch(natsMsgList **out, natsSubscription *sub, int count, int64_t timeout, jsErrCode *err) {
    return ham_nats_fetch_options(out, sub, count, timeout, 0, err);
}
int ham_nats_fetch_available(natsMsgList **out, natsSubscription *sub, int count, jsErrCode *err) {
    return ham_nats_fetch_options(out, sub, count, 1000, 1, err);
}
void ham_nats_batch_destroy(natsMsgList *list) {
    if (!list) return;
    natsMsgList_Destroy(list);
    free(list);
}
int ham_nats_batch_count(natsMsgList *list) { return list->Count; }
natsMsg *ham_nats_batch_message(natsMsgList *list, int index) {
    return index >= 0 && index < list->Count ? list->Msgs[index] : NULL;
}
int ham_nats_metadata(natsMsg *msg, ham_metadata *out) {
    jsMsgMetaData *meta = NULL;
    natsStatus s = natsMsg_GetMetaData(&meta, msg);
    if (s == NATS_OK) {
        out->stream_sequence = meta->Sequence.Stream;
        out->consumer_sequence = meta->Sequence.Consumer;
        out->num_delivered = meta->NumDelivered;
        out->num_pending = meta->NumPending;
    }
    jsMsgMetaData_Destroy(meta);
    return s;
}
int ham_nats_ack(natsMsg *msg, jsErrCode *err) { return natsMsg_AckSync(msg, NULL, err); }
int ham_nats_nak(natsMsg *msg) { return natsMsg_Nak(msg, NULL); }
int ham_nats_term(natsMsg *msg) { return natsMsg_Term(msg, NULL); }

// Persist the reply subject, not the C message: HTTP ack can arrive after the
// fetched batch has been destroyed. Request/reply confirms server receipt.
int ham_nats_ack_reply(ham_nats *h, const char *reply, int64_t timeout) {
    natsMsg *response = NULL;
    natsStatus s = natsConnection_Request(&response, h->nc, reply, "+ACK", 4, timeout);
    natsMsg_Destroy(response);
    return s;
}
int ham_nats_stream_get(natsMsg **out, ham_nats *h, const char *stream,
                         uint64_t sequence, jsErrCode *err) {
    *out = NULL;
    natsStatus s = js_GetMsg(out, h->js, stream, sequence, NULL, err);
    if (s != NATS_OK) { natsMsg_Destroy(*out); *out = NULL; }
    return s;
}

int ham_nats_api_stats(ham_nats *h, uint64_t *total, uint64_t *errors, jsErrCode *err) {
    jsAccountInfo *info = NULL;
    natsStatus s = js_GetAccountInfo(&info, h->js, NULL, err);
    if (s == NATS_OK) { *total = info->API.Total; *errors = info->API.Errors; }
    jsAccountInfo_Destroy(info);
    return s;
}

typedef struct { uint64_t delivered, pending, ack_pending, redelivered; } ham_consumer_state;
int ham_nats_consumer_state(ham_nats *h, const char *stream, const char *name,
                            ham_consumer_state *out, jsErrCode *err) {
    jsConsumerInfo *info = NULL;
    natsStatus s = js_GetConsumerInfo(&info, h->js, stream, name, NULL, err);
    if (s == NATS_OK) {
        out->delivered = info->Delivered.Stream;
        out->pending = info->NumPending;
        out->ack_pending = info->NumAckPending;
        out->redelivered = info->NumRedelivered;
    }
    jsConsumerInfo_Destroy(info);
    return s;
}
int ham_nats_subject_count(ham_nats *h, const char *stream, const char *filter,
                           uint64_t *count, jsErrCode *err) {
    jsOptions opts;
    jsStreamInfo *info = NULL;
    *count = 0;
    natsStatus s = jsOptions_Init(&opts);
    if (s != NATS_OK) return s;
    opts.Stream.Info.SubjectsFilter = filter;
    s = js_GetStreamInfo(&info, h->js, stream, &opts, err);
    if (s == NATS_OK && info->State.Subjects)
        for (int i = 0; i < info->State.Subjects->Count; i++)
            *count += info->State.Subjects->List[i].Msgs;
    jsStreamInfo_Destroy(info);
    return s;
}

// Subject-filtered direct get skips other tenants and rolled-up holes server-side.
// Return a normal owned message with its original subject; all direct info stays C.
int ham_nats_stream_next(natsMsg **out, ham_nats *h, const char *stream,
                         const char *filter, uint64_t start, uint64_t *sequence) {
    *out = NULL;
    *sequence = 0;
    jsDirectGetMsgOptions dg;
    natsMsg *msg = NULL;
    natsStatus s = jsDirectGetMsgOptions_Init(&dg);
    if (s != NATS_OK) return s;
    dg.Sequence = start;
    dg.NextBySubject = filter;
    s = js_DirectGetMsg(&msg, h->js, stream, NULL, &dg);
    if (s == NATS_NOT_FOUND) { natsMsg_Destroy(msg); return NATS_OK; }
    const char *seq = NULL, *subject = NULL;
    if (s == NATS_OK) s = natsMsgHeader_Get(msg, "Nats-Sequence", &seq);
    if (s == NATS_OK) s = natsMsgHeader_Get(msg, "Nats-Subject", &subject);
    if (s == NATS_OK) {
        if (!seq || !*seq || !subject || !*subject) s = NATS_ERR;
        for (const char *p = seq; s == NATS_OK && *p; p++) {
            if (*p < '0' || *p > '9' || *sequence > (UINT64_MAX - (*p - '0')) / 10)
                s = NATS_ERR;
            else *sequence = *sequence * 10 + (*p - '0');
        }
    }
    if (s == NATS_OK)
        s = natsMsg_Create(out, subject, NULL, natsMsg_GetData(msg), natsMsg_GetDataLength(msg));
    natsMsg_Destroy(msg);
    if (s != NATS_OK) { natsMsg_Destroy(*out); *out = NULL; }
    return s;
}
