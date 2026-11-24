// Private ABI adapter. All nats.c structs and their destruction stay here.
// No callbacks into Odin, including on reconnect/error paths.
#include <nats/nats.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { natsConnection *nc; jsCtx *js; } ham_nats;
typedef struct { uint64_t messages, first, last; } ham_stream_state;
typedef struct { uint64_t sequence; int duplicate; } ham_pub_ack;
typedef struct { uint64_t stream_sequence, consumer_sequence, num_delivered, num_pending; int64_t timestamp_ns; } ham_metadata;

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
                    int schedules, int ttl, int retention,
                    ham_stream_state *out, jsErrCode *err) {
    jsStreamInfo *info = NULL;
    jsStreamConfig cfg;
    natsStatus s = jsStreamConfig_Init(&cfg);
    if (s != NATS_OK) return s;
    cfg.Name = name;
    cfg.Subjects = subjects;
    cfg.SubjectsLen = count;
    cfg.Storage = js_FileStorage;
    cfg.Retention = retention == 1 ? js_WorkQueuePolicy : js_LimitsPolicy;
    cfg.MaxAge = max_age_ns;
    cfg.Duplicates = duplicate_ns;
    cfg.Replicas = replicas;
    cfg.AllowRollup = rollup != 0;
    cfg.AllowDirect = direct != 0;
    cfg.AllowMsgSchedules = schedules != 0;
    cfg.AllowMsgTTL = ttl != 0;
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
                          int64_t max_deliver, int64_t start_time_ns, int deliver_new,
                          int64_t max_ack_pending, jsErrCode *err) {
    jsConsumerInfo *info = NULL;
    jsConsumerConfig cfg;
    natsStatus s = jsConsumerConfig_Init(&cfg);
    if (s != NATS_OK) return s;
    cfg.Durable = durable;
    cfg.AckPolicy = js_AckExplicit;
    cfg.DeliverPolicy = deliver_new ? js_DeliverNew : js_DeliverAll;
    if (start_time_ns > 0) {
        cfg.DeliverPolicy = js_DeliverByStartTime;
        cfg.OptStartTime = start_time_ns;
    }
    cfg.AckWait = ack_wait_ns;
    cfg.MaxDeliver = max_deliver;
    if (max_ack_pending > 0) cfg.MaxAckPending = max_ack_pending;
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
        out->timestamp_ns = meta->Timestamp;
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
    if (s == NATS_NOT_FOUND) { natsMsg_Destroy(msg); return s; }
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

int ham_nats_server_version(ham_nats *h, const char *stream, char *out,
                            int size, jsErrCode *err) {
    jsStreamInfo *info = NULL;
    out[0] = 0;
    natsStatus s = js_GetStreamInfo(&info, h->js, stream, NULL, err);
    if (s == NATS_OK && info->Config) {
        natsMetadata *meta = &info->Config->Metadata;
        for (int i = 0; i < meta->Count; i++) {
            if (strcmp(meta->List[2*i], "_nats.ver") == 0) {
                const char *v = meta->List[2*i+1];
                if (strlen(v) >= (size_t)size) s = NATS_ERR;
                else memcpy(out, v, strlen(v)+1);
                break;
            }
        }
    }
    jsStreamInfo_Destroy(info);
    return s;
}
int ham_nats_request(natsMsg **out, ham_nats *h, const char *subject, const void *data, int len) {
    *out = NULL;
    return natsConnection_Request(out, h->nc, subject, data, len, 2000);
}
int ham_nats_publish_reply(ham_nats *h, const char *reply, const void *data, int len) {
    return natsConnection_Publish(h->nc, reply, data, len);
}
int ham_nats_flush(ham_nats *h) { return natsConnection_FlushTimeout(h->nc, 2000); }
// nats.c prefixes the server description with a source location. Generic
// JSStreamMsgDeleteFailedF (10057) is absent only for "no message found".
int ham_nats_delete_error_absent(int status, int code, const char *description) {
    if (status == NATS_NOT_FOUND || code == 10037) return 1;
    if (code != 10057 || description == NULL) return 0;
    if (description[0] == '(') {
        const char *prefix_end = strstr(description, "): ");
        if (prefix_end == NULL) return 0;
        description = prefix_end + 3;
    }
    return strcmp(description, "no message found") == 0;
}
int ham_nats_delete_message(ham_nats *h, const char *stream, uint64_t seq, int *deleted, jsErrCode *err) {
    *deleted = 0;
    natsStatus s = js_DeleteMsg(h->js, stream, seq, NULL, err);
    if (s == NATS_OK) *deleted = 1;
    else if (ham_nats_delete_error_absent(s, *err, nats_GetLastError(NULL))) {
        s = NATS_OK;
        *err = 0;
    }
    return s;
}

// A long server pull with short local receive waits. Only the owning forwarder
// uses this handle; conn_lock fences destruction. At most one request is live.
// Heartbeats let an idle server pull return regularly without another request.
typedef struct {
    ham_nats *owner;
    natsSubscription *sub;
    char *inbox, *subject;
    int remaining;
} ham_long_pull;
void ham_nats_long_pull_destroy(ham_long_pull *p) {
    if (!p) return;
    if (p->sub) natsSubscription_Unsubscribe(p->sub);
    natsSubscription_Destroy(p->sub);
    natsInbox_Destroy(p->inbox);
    free(p->subject);
    free(p);
}
int ham_nats_long_pull_bind(ham_long_pull **out, ham_nats *h,
                            const char *stream, const char *consumer) {
    *out = NULL;
    ham_long_pull *p = calloc(1, sizeof(*p));
    if (!p) return NATS_NO_MEMORY;
    p->owner = h;
    size_t size = strlen(stream) + strlen(consumer) + 32;
    p->subject = malloc(size);
    if (!p->subject) { ham_nats_long_pull_destroy(p); return NATS_NO_MEMORY; }
    snprintf(p->subject, size, "$JS.API.CONSUMER.MSG.NEXT.%s.%s", stream, consumer);
    natsStatus s = natsInbox_Create(&p->inbox);
    if (s == NATS_OK) s = natsConnection_SubscribeSync(&p->sub, h->nc, p->inbox);
    if (s != NATS_OK) { ham_nats_long_pull_destroy(p); return s; }
    *out = p;
    return NATS_OK;
}
int ham_nats_long_pull_next(natsMsg **out, ham_long_pull *p, int limit,
                             int64_t wait_ms, int *requested) {
    *out = NULL;
    *requested = 0;
    if (p->remaining == 0) {
        if (limit <= 0) return NATS_TIMEOUT;
        char body[128];
        int size = snprintf(body, sizeof(body),
            "{\"batch\":%d,\"expires\":30000000000,\"idle_heartbeat\":500000000}", limit);
        natsStatus s = natsConnection_PublishRequest(p->owner->nc, p->subject, p->inbox, body, size);
        if (s != NATS_OK) return s;
        p->remaining = limit;
        *requested = 1;
    }
    natsStatus s = natsSubscription_NextMsg(out, p->sub, wait_ms);
    if (s != NATS_OK) return s;
    const char *status = NULL;
    if (natsMsgHeader_Get(*out, "Status", &status) == NATS_OK && status) {
        int code = atoi(status);
        natsMsg_Destroy(*out); *out = NULL;
        if (code == 100) return NATS_TIMEOUT;
        p->remaining = 0;
        if (code == 404 || code == 408) return NATS_TIMEOUT;
        return NATS_ERR;
    }
    p->remaining--;
    return NATS_OK;
}

// Core subscriptions are wake hints only; durable delivery stays in JetStream.
// A synchronous Odin-owned waiter receives them, never a C callback into Odin.
int ham_nats_core_subscribe(natsSubscription **out, ham_nats *h, const char *subject) {
    *out = NULL;
    natsStatus s = natsConnection_SubscribeSync(out, h->nc, subject);
    if (s == NATS_OK) s = natsConnection_Flush(h->nc);
    if (s != NATS_OK) {
        natsSubscription_Destroy(*out);
        *out = NULL;
    }
    return s;
}
