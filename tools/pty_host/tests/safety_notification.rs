use ham_pty_host::delivery::{Delivery, Deliveries, PREPARE, DISPATCH};

fn intent(text: &str) -> Delivery {
    Delivery { instance:"inst".into(), pid:42, launch_key:"key".into(), launch_epoch:"epoch".into(), run_count:"1".into(), operation_id:"op".into(), delivery_id:"delivery".into(), message:text.as_bytes().to_vec(), interrupt:false }
}

#[test]
fn notification_accepts_valid_unicode_text() {
    for text in ["€", "😀", "Ā", "日本語"] {
        assert!(intent(text).valid(), "valid R1 Unicode text rejected: {text}");
    }
}

#[test]
fn notification_multiline_is_literal_paste() {
    let d = intent("first\nsecond\ttext");
    assert!(d.valid());
    let mut store=Deliveries::default();
    let mut bytes=Vec::new();
    let p=store.apply(&d,PREPARE,"",&mut bytes).unwrap();
    store.apply(&d,DISPATCH,&p.ticket,&mut bytes).unwrap();
    assert_eq!(bytes, b"\x1b[200~first\nsecond\ttext\x1b[201~\r", "message controls must be inside literal paste before final Enter");
}
