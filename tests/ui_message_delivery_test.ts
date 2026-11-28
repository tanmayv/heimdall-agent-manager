// Message delivery result (R7 D5): the TS mirror of src/contracts/message_delivery.odin.
// RUN: node --test tests/ui_message_delivery_test.ts
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { MESSAGE_DELIVERY_ACCEPTED, MESSAGE_DELIVERY_PENDING, messageDeliveryOf } from '../src/ui/api/messageDelivery.ts';

test('the TS mirror names the same states and reasons as the Odin contract', () => {
  const contract = readFileSync(new URL('../src/contracts/message_delivery.odin', import.meta.url), 'utf8');
  assert.match(contract, new RegExp(`MESSAGE_DELIVERY_ACCEPTED :: "${MESSAGE_DELIVERY_ACCEPTED}"`));
  assert.match(contract, new RegExp(`MESSAGE_DELIVERY_PENDING :: "${MESSAGE_DELIVERY_PENDING}"`));
  const mirror = readFileSync(new URL('../src/ui/api/messageDelivery.ts', import.meta.url), 'utf8');
  for (const [, reason] of contract.matchAll(/MESSAGE_DELIVERY_REASON_[A-Z_]+ :: "([a-z_]+)"/g)) {
    assert.ok(mirror.includes(`'${reason}'`), `reason ${reason} is mirrored`);
  }
});

test('messageDeliveryOf reads the send response and ignores unknown states', () => {
  assert.deepEqual(messageDeliveryOf({ message_id: 'm', delivery: { state: 'pending', reason: 'agent_not_running' } }), { state: 'pending', reason: 'agent_not_running' });
  assert.deepEqual(messageDeliveryOf({ data: { delivery: { state: 'accepted', reason: '' } } }), { state: 'accepted', reason: '' });
  assert.equal(messageDeliveryOf({ delivery: { state: 'delivered' } }), undefined);
  assert.equal(messageDeliveryOf({ message_id: 'm' }), undefined);
});
