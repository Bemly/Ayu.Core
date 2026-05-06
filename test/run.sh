#!/bin/sh
# test/run.sh — Ayu.Core test runner
# Usage: docker run --rm -v $(pwd):/ayu busybox:musl sh /ayu/test/run.sh

cd "$(dirname "$0")/.." || exit 1
. ./lib/core.sh
. ./lib/log.sh
. ./lib/http.sh
. ./lib/dispatch.sh
. ./etc/config.sh
. ./adapter/qq/system.sh
. ./adapter/qq/message.sh
. ./adapter/qq/webhook.sh
. ./adapter/telegram/core.sh
. ./adapter/telegram/bot.sh
. ./adapter/telegram/message.sh
. ./adapter/telegram/chat.sh
. ./adapter/telegram/admin.sh
. ./adapter/telegram/inline.sh
. ./adapter/telegram/file.sh
. ./adapter/telegram/commands.sh
. ./adapter/telegram/webhook.sh
. ./adapter/telegram/profile.sh
. ./adapter/telegram/sticker.sh
. ./adapter/telegram/payment.sh
. ./adapter/telegram/game.sh
. ./adapter/telegram/business.sh
. ./adapter/telegram/story.sh
. ./adapter/telegram/gift.sh
. ./adapter/telegram/misc.sh
. ./adapter/discord/core.sh
. ./adapter/discord/message.sh
. ./adapter/discord/channel.sh
. ./adapter/discord/guild.sh
. ./adapter/discord/webhook.sh
. ./adapter/discord/user.sh
. ./adapter/discord/application.sh
. ./adapter/discord/emoji.sh
. ./adapter/discord/sticker.sh
. ./adapter/discord/automod.sh
. ./adapter/discord/event.sh
. ./adapter/discord/template.sh
. ./adapter/discord/invite.sh
. ./adapter/discord/stage.sh
. ./adapter/discord/voice.sh
. ./adapter/discord/audit.sh
. ./adapter/discord/poll.sh
. ./adapter/discord/soundboard.sh
. ./adapter/discord/monetize.sh
. ./test/helper.sh
. ./test/mock/mock_http.sh

# run all test files
for _f in test/test_*.sh; do
    printf '\n--- %s ---\n' "$_f"
    . "./$_f"
done

printf '\n'
test_summary
