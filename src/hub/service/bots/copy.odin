package bots

import domain "odin_test:hub/domain"

COPY_PAIRED :: "Connected to your Ninjy bot. Messages in this chat are not end-to-end encrypted: Telegram and your Ninjy hub can read them. Anyone who can send messages from this Telegram account can instruct your bot, which runs commands on your machines. Send /disconnect to disconnect."
COPY_PAIR_INVALID :: "This link has expired or was already used. Open Settings > Bots in Ninjy to get a new one."
COPY_PAIR_CHAT_TAKEN :: "This Telegram chat is already connected to another Ninjy account."
COPY_PAIR_NOT_ENABLED :: "Bots are not enabled for this Ninjy account. Turn on Bots in Settings > Experimental, then try again."
COPY_PAIR_NO_BOT :: "You have no Ninjy bot yet. Create one in Settings > Bots, then use the Connect link."
COPY_NOT_CONNECTED :: "This chat is not connected to Ninjy. Open Settings > Bots in Ninjy to connect it."
COPY_PRIVATE_ONLY :: "Ninjy bots work only in private chats."
COPY_UNSUPPORTED :: "Ninjy bots accept text, photos, documents, videos and voice notes. Stickers, locations, contacts and polls are not supported."
COPY_REPLACED :: "This chat was disconnected from Ninjy because another chat was connected."
COPY_DISCONNECTED :: "Disconnected from Ninjy. Your messages here are no longer delivered to your bot."
COPY_NO_MACHINE :: "No machine is available right now. Your message is saved and will be answered when one is."
COPY_GAVE_UP :: "Your bot could not answer after several tries. Your message is saved; send another message to try again."


COPY_WA_PAIRED :: "Connected to your Ninjy bot. WhatsApp's end-to-end encryption ends at Meta's business messaging service: Meta and your Ninjy hub can read messages in this chat. Anyone who can send messages from this WhatsApp account can instruct your bot, which runs commands on your machines. Send disconnect to disconnect."
COPY_WA_PAIR_INVALID :: "This connect code has expired or was already used. Open Settings > Bots in Ninjy and choose Connect WhatsApp to get a new one."
COPY_WA_CHAT_TAKEN :: "This WhatsApp account is already connected to another Ninjy account."
COPY_WA_NOT_CONNECTED :: "This WhatsApp account is not connected to Ninjy. Open Settings > Bots in Ninjy and choose Connect WhatsApp."
COPY_WA_INVITE_ONLY :: "WhatsApp access is invite-only for now."
COPY_WA_INVITE_ONLY_SETTINGS :: "WhatsApp is invite-only — ask the admin for access."
COPY_WA_REPLACED :: "This WhatsApp account was disconnected from Ninjy because another WhatsApp account was connected."

Bot_Channel_Copy :: struct { paired, pair_invalid, chat_taken, not_connected, replaced: string }
bots_channel_copy :: proc(provider: string) -> Bot_Channel_Copy {
	if provider == domain.CHANNEL_PROVIDER_WHATSAPP do return {COPY_WA_PAIRED, COPY_WA_PAIR_INVALID, COPY_WA_CHAT_TAKEN, COPY_WA_NOT_CONNECTED, COPY_WA_REPLACED}
	return {COPY_PAIRED, COPY_PAIR_INVALID, COPY_PAIR_CHAT_TAKEN, COPY_NOT_CONNECTED, COPY_REPLACED}
}

COPY_MEDIA_TOO_LARGE :: "This file is too large for your Ninjy bot. Send files up to 15 MB, or share a link instead."
COPY_MEDIA_LINK_FORMAT :: "📎 %s: %s\nOpens after you sign in to Ninjy."
COPY_MEDIA_LINK_NO_ORIGIN_FORMAT :: "📎 %s: open Ninjy, go to Library and find artifact %s."
COPY_MEDIA_DEFAULT_LINK_NAME :: "File"
