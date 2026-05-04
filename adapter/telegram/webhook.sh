# Telegram webhook — parse update events

# Extract descriptive text from a Telegram Message object
# Handles all content types: text, caption, photo, video, voice, sticker, etc.
tg_extract_text() {
	_msg="$1"

	# 1. Plain text
	_txt="$(json_get "$_msg" text 2>/dev/null)" || _txt=""
	if [ -n "$_txt" ] && [ "$_txt" != "NOTFOUND" ]; then
		printf '%s' "$_txt"
		return
	fi

	# 2. Caption (for media with description)
	_cap="$(json_get "$_msg" caption 2>/dev/null)" || _cap=""
	[ "$_cap" = "NOTFOUND" ] && _cap=""

	# 3. Detect media type and build label
	_label=""

	# photo
	_ph="$(json_get "$_msg" photo 2>/dev/null)" || _ph=""
	if [ -n "$_ph" ] && [ "$_ph" != "NOTFOUND" ]; then
		_label="[图片]"
	fi

	# voice
	if [ -z "$_label" ]; then
		_vc="$(json_get "$_msg" voice 2>/dev/null)" || _vc=""
		[ -n "$_vc" ] && [ "$_vc" != "NOTFOUND" ] && _label="[语音]"
	fi

	# video
	if [ -z "$_label" ]; then
		_vd="$(json_get "$_msg" video 2>/dev/null)" || _vd=""
		[ -n "$_vd" ] && [ "$_vd" != "NOTFOUND" ] && _label="[视频]"
	fi

	# video_note
	if [ -z "$_label" ]; then
		_vn="$(json_get "$_msg" video_note 2>/dev/null)" || _vn=""
		[ -n "$_vn" ] && [ "$_vn" != "NOTFOUND" ] && _label="[视频笔记]"
	fi

	# animation (GIF)
	if [ -z "$_label" ]; then
		_an="$(json_get "$_msg" animation 2>/dev/null)" || _an=""
		[ -n "$_an" ] && [ "$_an" != "NOTFOUND" ] && _label="[动画]"
	fi

	# audio
	if [ -z "$_label" ]; then
		_au="$(json_get "$_msg" audio 2>/dev/null)" || _au=""
		if [ -n "$_au" ] && [ "$_au" != "NOTFOUND" ]; then
			_title="$(json_get "$_au" title 2>/dev/null)" || _title=""
			if [ -n "$_title" ] && [ "$_title" != "NOTFOUND" ]; then
				_label="[音频: $_title]"
			else
				_label="[音频]"
			fi
		fi
	fi

	# document (file)
	if [ -z "$_label" ]; then
		_dc="$(json_get "$_msg" document 2>/dev/null)" || _dc=""
		if [ -n "$_dc" ] && [ "$_dc" != "NOTFOUND" ]; then
			_fn="$(json_get "$_dc" file_name 2>/dev/null)" || _fn=""
			if [ -n "$_fn" ] && [ "$_fn" != "NOTFOUND" ]; then
				_label="[文件: $_fn]"
			else
				_label="[文件]"
			fi
		fi
	fi

	# sticker
	if [ -z "$_label" ]; then
		_st="$(json_get "$_msg" sticker 2>/dev/null)" || _st=""
		if [ -n "$_st" ] && [ "$_st" != "NOTFOUND" ]; then
			_emoji="$(json_get "$_st" emoji 2>/dev/null)" || _emoji=""
			if [ -n "$_emoji" ] && [ "$_emoji" != "NOTFOUND" ]; then
				_label="[贴纸: $_emoji]"
			else
				_label="[贴纸]"
			fi
		fi
	fi

	# location
	if [ -z "$_label" ]; then
		_lc="$(json_get "$_msg" location 2>/dev/null)" || _lc=""
		[ -n "$_lc" ] && [ "$_lc" != "NOTFOUND" ] && _label="[位置]"
	fi

	# contact
	if [ -z "$_label" ]; then
		_ct="$(json_get "$_msg" contact 2>/dev/null)" || _ct=""
		[ -n "$_ct" ] && [ "$_ct" != "NOTFOUND" ] && _label="[联系人]"
	fi

	# dice
	if [ -z "$_label" ]; then
		_di="$(json_get "$_msg" dice 2>/dev/null)" || _di=""
		[ -n "$_di" ] && [ "$_di" != "NOTFOUND" ] && _label="[骰子]"
	fi

	# poll
	if [ -z "$_label" ]; then
		_pl="$(json_get "$_msg" poll 2>/dev/null)" || _pl=""
		[ -n "$_pl" ] && [ "$_pl" != "NOTFOUND" ] && _label="[投票]"
	fi

	# venue
	if [ -z "$_label" ]; then
		_vn="$(json_get "$_msg" venue 2>/dev/null)" || _vn=""
		[ -n "$_vn" ] && [ "$_vn" != "NOTFOUND" ] && _label="[地点]"
	fi

	# game
	if [ -z "$_label" ]; then
		_gm="$(json_get "$_msg" game 2>/dev/null)" || _gm=""
		[ -n "$_gm" ] && [ "$_gm" != "NOTFOUND" ] && _label="[游戏]"
	fi

	# Build output: [prefix] [label] + caption text
	_prefix=""

	# reply
	_reply="$(json_get "$_msg" reply_to_message 2>/dev/null)" || _reply=""
	if [ -n "$_reply" ] && [ "$_reply" != "NOTFOUND" ]; then
		_rt="$(tg_extract_text "$_reply")"
		[ -n "$_rt" ] && _prefix="$_prefix[回复: $_rt] "
	fi

	# forward
	_fwd="$(json_get "$_msg" forward_origin 2>/dev/null)" || _fwd=""
	if [ -n "$_fwd" ] && [ "$_fwd" != "NOTFOUND" ]; then
		_prefix="$_prefix[转发] "
	fi

	# Service messages (no text/media detected)
	if [ -z "$_label" ] && [ -z "$_cap" ]; then
		_new="$(json_get "$_msg" new_chat_members 2>/dev/null)" || _new=""
		[ -n "$_new" ] && [ "$_new" != "NOTFOUND" ] && _label="[新成员加入]"
		_left="$(json_get "$_msg" left_chat_member 2>/dev/null)" || _left=""
		[ -n "$_left" ] && [ "$_left" != "NOTFOUND" ] && _label="[成员离开]"
		_pin="$(json_get "$_msg" pinned_message 2>/dev/null)" || _pin=""
		[ -n "$_pin" ] && [ "$_pin" != "NOTFOUND" ] && _label="[置顶消息]"
		_title="$(json_get "$_msg" new_chat_title 2>/dev/null)" || _title=""
		if [ -n "$_title" ] && [ "$_title" != "NOTFOUND" ]; then
			_label="[群名改为: $_title]"
		fi
		_tpc="$(json_get "$_msg" forum_topic_created 2>/dev/null)" || _tpc=""
		[ -n "$_tpc" ] && [ "$_tpc" != "NOTFOUND" ] && _label="[新话题]"
		if [ -n "$(json_get "$_msg" forum_topic_closed 2>/dev/null)" 2>/dev/null ]; then
			_label="[话题关闭]"
		fi
		if [ -n "$(json_get "$_msg" forum_topic_reopened 2>/dev/null)" 2>/dev/null ]; then
			_label="[话题重开]"
		fi
	fi

	if [ -n "$_cap" ]; then
		printf '%s%s %s' "$_prefix" "$_label" "$_cap"
	else
		printf '%s%s' "$_prefix" "$_label"
	fi
}

# Handle a Message update (message / channel_post / edited_message)
_tg_dispatch_msg() {
	_msg="$1" _evt="$2"
	_txt="$(tg_extract_text "$_msg")"
	_chat="$(json_get "$_msg" chat 2>/dev/null)" || _chat=""
	_cid="$(json_get "$_chat" id 2>/dev/null)" || _cid=""
	[ "$_cid" = "NOTFOUND" ] && _cid=""
	_has_ani="$(json_get "$_msg" animation 2>/dev/null)" || _has_ani=""
	_has_doc="$(json_get "$_msg" document 2>/dev/null)" || _has_doc=""
	_has_pho="$(json_get "$_msg" photo 2>/dev/null)" || _has_pho=""
	_has_vid="$(json_get "$_msg" video 2>/dev/null)" || _has_vid=""
	log_info "tg_webhook: $_evt chat=$_cid text=$_txt has={ani=$([ -n "$_has_ani" ] && [ "$_has_ani" != NOTFOUND ] && echo 1 || echo 0) doc=$([ -n "$_has_doc" ] && [ "$_has_doc" != NOTFOUND ] && echo 1 || echo 0) pho=$([ -n "$_has_pho" ] && [ "$_has_pho" != NOTFOUND ] && echo 1 || echo 0) vid=$([ -n "$_has_vid" ] && [ "$_has_vid" != NOTFOUND ] && echo 1 || echo 0)}"
	dispatch "telegram" "message" "$_cid" "$_txt" "$_msg"
}

tg_webhook() {
	_raw="$1"

	_msg="$(json_get "$_raw" message 2>/dev/null)" || _msg=""
	if [ -n "$_msg" ] && [ "$_msg" != "NOTFOUND" ]; then
		_tg_dispatch_msg "$_msg" "message"
		return 0
	fi

	_msg="$(json_get "$_raw" channel_post 2>/dev/null)" || _msg=""
	if [ -n "$_msg" ] && [ "$_msg" != "NOTFOUND" ]; then
		_tg_dispatch_msg "$_msg" "channel_post"
		return 0
	fi

	_msg="$(json_get "$_raw" edited_message 2>/dev/null)" || _msg=""
	if [ -n "$_msg" ] && [ "$_msg" != "NOTFOUND" ]; then
		_tg_dispatch_msg "$_msg" "edited_message"
		return 0
	fi

	_cb="$(json_get "$_raw" callback_query 2>/dev/null)" || _cb=""
	if [ -n "$_cb" ] && [ "$_cb" != "NOTFOUND" ]; then
		_data="$(json_get "$_cb" data 2>/dev/null)" || _data=""
		log_info "tg_webhook: callback data=$_data"
		dispatch "telegram" "callback" "" "$_data" "$_cb"
		return 0
	fi


	_reaction="$(json_get "$_raw" message_reaction 2>/dev/null)" || _reaction=""
	if [ -n "$_reaction" ] && [ "$_reaction" != "NOTFOUND" ]; then
		_rchat="$(json_get "$_reaction" chat)" || _rchat=""
		_rcid="$(json_get "$_rchat" id 2>/dev/null)" || _rcid=""
		_rmid="$(json_get "$_reaction" message_id 2>/dev/null)" || _rmid=""
		log_info "tg_webhook: reaction chat=$_rcid msg=$_rmid"
		dispatch "telegram" "reaction" "$_rcid" "$_rmid" "$_reaction"
		return 0
	fi
	log_debug "tg_webhook: unhandled update type"
	return 0
}
