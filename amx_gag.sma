#include < amxmodx >
#include < amxmisc >
#include < engine >
#include < regex >

#define MAX_PLAYERS 32

#define MAX_PATTERN_LEN 255

enum ( <<= 1 )
{
	GAG_CHAT = 1,
	GAG_TEAMSAY,
	GAG_VOICE
};

enum _:GagData
{
	GAG_AUTHID[ 35 ],
	GAG_TIME,
	GAG_START,
	GAG_FLAGS
};

enum _:TimeUnit
{
	TIMEUNIT_SECONDS = 0,
	TIMEUNIT_MINUTES,
	TIMEUNIT_HOURS,
	TIMEUNIT_DAYS,
	TIMEUNIT_WEEKS
};

new const g_szTimeUnitName[ TimeUnit ][ 2 ][ ] =
{
	{ "second", "seconds" },
	{ "minute", "minutes" },
	{ "hour",   "hours"   },
	{ "day",    "days"    },
	{ "week",   "weeks"   }
};

new const g_iTimeUnitMult[ TimeUnit ] =
{
	1,
	60,
	3600,
	86400,
	604800
};

new Array:g_aGagTimes;
new Array:g_aGagData;
new Trie:g_tArrayPos;
new Trie:g_tTimeUnitWords;

new g_iGagged;
new g_iThinker;
new g_iTotalGagTimes;
new g_iMsgSayText;

new g_szAuthid[ MAX_PLAYERS + 1 ][ 35 ];
new g_iMenuOption[ MAX_PLAYERS + 1 ];
new g_iMenuPosition[ MAX_PLAYERS + 1 ];
new g_iMenuPlayers[ MAX_PLAYERS + 1 ][ 32 ];
new g_iMenuFlags[ MAX_PLAYERS + 1 ];

new g_szGagFile[ 64 ];

new bool:g_bColorSupported;

new g_pCvarDefaultFlags;
new g_pCvarDefaultTime;
new g_pCvarTimeUnit;
new g_pCvarMaxTime;

enum _:WhiteListData
{
	WHITELIST_PATTERN,
	WHITELIST_SAYAREA
};

new Array:g_aWhiteLists;
new g_iNumWhiteLists;
new g_iReturnFromRegex;

public plugin_init( )
{
	register_plugin( "AMXX Gag", "1.4.5b", "xPaw & Exolent" );
	
	register_clcmd( "say",        "CmdSay" );
	register_clcmd( "say_team",   "CmdTeamSay" );
	
	register_concmd( "amx_gag",       "CmdGagPlayer",   ADMIN_KICK, "<nick or #userid> <time> <a|b|c> -- Use 0 time for permanent" );
	register_concmd( "amx_addgag",    "CmdAddGag",      ADMIN_KICK, "<authid> <time> <a|b|c> -- Use 0 time for permanent" );
	register_concmd( "amx_ungag",     "CmdUnGagPlayer", ADMIN_KICK, "<nick or #userid>" );
	register_concmd( "amx_gagmenu",   "CmdGagMenu",     ADMIN_KICK, "- displays gag menu" );
	register_srvcmd( "amx_gag_times", "CmdSetBanTimes" );
	
	register_menu( "Gag Menu", 1023, "ActionGagMenu" );
	register_menu( "Gag Flags", 1023, "ActionGagFlags" );
	register_message( get_user_msgid( "SayText" ), "MessageSayText" );
	
	g_pCvarDefaultFlags = register_cvar( "amx_gag_default_flags", "abc"   );
	g_pCvarDefaultTime  = register_cvar( "amx_gag_default_time",  "600"   );
	g_pCvarTimeUnit     = register_cvar( "amx_gag_time_units",    "0"     );
	g_pCvarMaxTime      = register_cvar( "amx_gag_max_time",      "86400" );
	
	g_tArrayPos       = TrieCreate( );
	g_aGagTimes       = ArrayCreate( );
	g_aGagData        = ArrayCreate( GagData );
	g_bColorSupported = bool:colored_menus( );
	g_iMsgSayText     = get_user_msgid( "SayText" );
	
	// let words work with the time unit cvar
	g_tTimeUnitWords = TrieCreate( );
	
	for( new i = 0; i < TimeUnit; i++ )
	{
		TrieSetCell( g_tTimeUnitWords, g_szTimeUnitName[ i ][ 0 ], i );
		TrieSetCell( g_tTimeUnitWords, g_szTimeUnitName[ i ][ 1 ], i );
	}
	
	// this is used for ungag in the menu
	ArrayPushCell( g_aGagTimes, 0 );
	
	// Gag times for the gag menu (amx_gagmenu)
	// Default values: 60 300 600 1800 3600 7200 86400
	
	// Load up standart times
	ArrayPushCell( g_aGagTimes, 60 );
	ArrayPushCell( g_aGagTimes, 300 );
	ArrayPushCell( g_aGagTimes, 600 );
	ArrayPushCell( g_aGagTimes, 1800 );
	ArrayPushCell( g_aGagTimes, 3600 );
	ArrayPushCell( g_aGagTimes, 7200 );
	ArrayPushCell( g_aGagTimes, 86400 );
	ArrayPushCell( g_aGagTimes, 0 ); // 0 = permanent
	
	g_iTotalGagTimes = ArraySize( g_aGagTimes );
	
	// Set up entity-thinker
	new const szClassName[ ] = "gag_thinker";
	
	g_iThinker = create_entity( "info_target" );
	entity_set_string( g_iThinker, EV_SZ_classname, szClassName );
	
	register_think( szClassName, "FwdThink" );
	
	// load gags from file
	get_datadir( g_szGagFile, charsmax( g_szGagFile ) );
	add( g_szGagFile, charsmax( g_szGagFile ), "/gags.txt" );
	
	LoadFromFile( );
	
	// prepare for white listing
	g_aWhiteLists = ArrayCreate( WhiteListData );
	
	LoadWhiteLists( );
}

public plugin_end( )
{
	TrieDestroy( g_tArrayPos );
	ArrayDestroy( g_aGagData );
	ArrayDestroy( g_aGagTimes );
	TrieDestroy( g_tTimeUnitWords );
	
	if( g_iNumWhiteLists )
	{
		new data[ WhiteListData ];
		
		for( new i = 0; i < g_iNumWhiteLists; i++ )
		{
			ArrayGetArray( g_aWhiteLists, i, data );
			
			regex_free( Regex:data[ WHITELIST_PATTERN ] );
		}
	}
	
	ArrayDestroy( g_aWhiteLists );
}

public CmdSetBanTimes( )
{
	new iArgs = read_argc( );
	
	if( iArgs <= 1 )
	{
		server_print( "Usage: amx_gag_times <time1> [time2] [time3] ..." );
		return PLUGIN_HANDLED;
	}
	
	ArrayClear( g_aGagTimes );
	
	// this is used for ungag in the menu
	ArrayPushCell( g_aGagTimes, 0 );
	
	// get max time allowed
	new iTimeLimit = get_pcvar_num( g_pCvarMaxTime );
	
	new szBuffer[ 32 ], iTime;
	for( new i = 1; i < iArgs; i++ )
	{
		read_argv( i, szBuffer, 31 );
		
		if( !is_str_num( szBuffer ) )
		{
			server_print( "[AMXX GAG] Time must be an integer!" );
			continue;
		}
		
		iTime = str_to_num( szBuffer );
		
		if( iTime < 0 )
		{
			server_print( "[AMXX GAG] Time must be a positive integer!" );
			continue;
		}
		
		if( 0 < iTimeLimit < iTime )
		{
			server_print( "[AMXX GAG] Time more then %d is not allowed!", iTimeLimit );
			continue;
		}
		
		ArrayPushCell( g_aGagTimes, iTime );
	}
	
	g_iTotalGagTimes = ArraySize( g_aGagTimes );
	
	return PLUGIN_HANDLED;
}

public client_putinserver( id )
{
	if( CheckGagFlag( id, GAG_VOICE ) )
	{
		set_speak( id, SPEAK_MUTED );
	}
	
	// default flags to "abc"
	g_iMenuFlags[ id ] = GAG_CHAT | GAG_TEAMSAY | GAG_VOICE;
}

public client_authorized( id )
	get_user_authid( id, g_szAuthid[ id ], 34 );

public client_disconnect( id )
{
	if( TrieKeyExists( g_tArrayPos, g_szAuthid[ id ] ) )
	{
		new szName[ 32 ];
		get_user_name( id, szName, 31 );
		
		new iPlayers[ 32 ], iNum, iPlayer;
		get_players( iPlayers, iNum, "ch" );
		
		for( new i; i < iNum; i++ )
		{
			iPlayer = iPlayers[ i ];
			
			if( get_user_flags( iPlayer ) & ADMIN_KICK )
			{
				if( g_bColorSupported )
				{
					GreenPrint( iPlayer, id, "^4[AMXX GAG]^1 Gagged player ^"^3%s^1<^4%s^1>^" has disconnected!", szName, g_szAuthid[ id ] );
				}
				else
				{
					client_print( iPlayer, print_chat, "[AMXX GAG] Gagged player ^"%s<%s>^" has disconnected!", szName, g_szAuthid[ id ] );
				}
			}
		}
	}
	
	g_szAuthid[ id ][ 0 ] = '^0';
}

public client_infochanged( id )
{
	if( !CheckGagFlag( id, ( GAG_CHAT | GAG_TEAMSAY ) ) )
	{
		return;
	}
	
	static const name[ ] = "name";
	
	static szNewName[ 32 ], szOldName[ 32 ];
	get_user_info( id, name, szNewName, 31 );
	get_user_name( id, szOldName, 31 );
	
	if( !equal( szNewName, szOldName ) )
	{
		if( g_bColorSupported )
		{
			GreenPrint( id, id, "^4[AMXX GAG]^1 Gagged players cannot change their names!" );
		}
		else
		{
			client_print( id, print_chat, "[AMXX GAG] Gagged players cannot change their names!" );
		}
		
		set_user_info( id, name, szOldName );
	}
}

public MessageSayText( )
{
	static const Cstrike_Name_Change[ ] = "#Cstrike_Name_Change";
	
	new szMessage[ sizeof( Cstrike_Name_Change ) + 1 ];
	get_msg_arg_string( 2, szMessage, charsmax( szMessage ) );
	
	if( equal( szMessage, Cstrike_Name_Change ) )
	{
		new szName[ 32 ], id;
		for( new i = 3; i <= 4; i++ )
		{
			get_msg_arg_string( i, szName, 31 );
			
			id = get_user_index( szName );
			
			if( is_user_connected( id ) )
			{
				if( CheckGagFlag( id, ( GAG_CHAT | GAG_TEAMSAY ) ) )
				{
					return PLUGIN_HANDLED;
				}
				
				break;
			}
		}
	}
	
	return PLUGIN_CONTINUE;
}

public FwdThink( const iEntity )
{
	if( !g_iGagged )
		return;
	
	new iSystime = get_systime( );
	new bool:bRemovedGags = false;
	
	new data[ GagData ], id, szName[ 32 ];
	for( new i = 0; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		
		if( data[ GAG_TIME ] > 0 && ( data[ GAG_START ] + data[ GAG_TIME ] ) <= iSystime )
		{
			id = find_player( "c", data[ GAG_AUTHID ] );
			
			if( is_user_connected( id ) )
			{
				get_user_name( id, szName, 31 );
				
				if( g_bColorSupported )
				{
					GreenPrint( 0, id, "^4[AMXX GAG]^1 Player ^"^3%s^1^" is no longer gagged", szName );
				}
				else
				{
					client_print( 0, print_chat, "[AMXX GAG] Player ^"%s^" is no longer gagged", szName );
				}
			}
			else
			{
				if( g_bColorSupported )
				{
					GreenPrint( 0, 0, "^4[AMXX GAG]^1 SteamID ^"^3%s^1^" is no longer gagged", data[ GAG_AUTHID ] );
				}
				else
				{
					client_print( 0, print_chat, "[AMXX GAG] SteamID ^"%s^" is no longer gagged", data[ GAG_AUTHID ] );
				}
			}
			
			DeleteGag( i-- );
			
			bRemovedGags = true;
		}
	}
	
	if( bRemovedGags )
	{
		SaveToFile( );
	}
	
	if( !g_iGagged )
		return;
	
	new iNextTime = 999999;
	for( new i = 0; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		
		if( data[ GAG_TIME ] > 0 )
			iNextTime = min( iNextTime, data[ GAG_START ] + data[ GAG_TIME ] - iSystime );
	}
	
	if( iNextTime < 999999 )
		entity_set_float( iEntity, EV_FL_nextthink, get_gametime( ) + iNextTime );
}

public CmdSay( const id )
	return CheckSay( id, 0 );

public CmdTeamSay( const id )
	return CheckSay( id, 1 );

CheckSay( const id, const bTeam )
{
	new iArrayPos;
	if( TrieGetCell( g_tArrayPos, g_szAuthid[ id ], iArrayPos ) )
	{
		new data[ GagData ];
		ArrayGetArray( g_aGagData, iArrayPos, data );
		
		new const iFlags[ ] = { GAG_CHAT, GAG_TEAMSAY };
		
		if( data[ GAG_FLAGS ] & iFlags[ bTeam ] )
		{
			// player is gagged, check if they were allowed to say what they said
			if( g_iNumWhiteLists )
			{
				new szSaid[ 194 ];
				read_args( szSaid, charsmax( szSaid ) );
				remove_quotes( szSaid );
				
				new whiteList[ WhiteListData ], iSayFlag = ( 1 << bTeam );
				
				for( new i = 0; i < g_iNumWhiteLists; i++ )
				{
					ArrayGetArray( g_aWhiteLists, i, whiteList );
					
					if( whiteList[ WHITELIST_SAYAREA ] & iSayFlag
					&& regex_match_c( szSaid, Regex:whiteList[ WHITELIST_PATTERN ], g_iReturnFromRegex ) > 0 )
					{
						// player was allowed to say this
						// don't say they were gagged
						// but still hide this from chat
						return PLUGIN_HANDLED_MAIN;
					}
				}
			}
			
			if( data[ GAG_TIME ] > 0 )
			{
				new szInfo[ 128 ], iTime = data[ GAG_START ] + data[ GAG_TIME ] - get_systime( );
				
				GetTimeLength( iTime, szInfo, charsmax( szInfo ) );
				
				if( g_bColorSupported )
				{
					GreenPrint( id, id, "^4[AMXX GAG]^3 %s^1 left before your ungag!", szInfo );
				}
				else
				{
					client_print( id, print_chat, "[AMXX GAG] %s left before your ungag!", szInfo );
				}
			}
			else
			{
				if( g_bColorSupported )
				{
					GreenPrint( id, id, "^4[AMXX GAG]^3 You are gagged permanently!" );
				}
				else
				{
					client_print( id, print_chat, "[AMXX GAG] You are gagged permanently!" );
				}
			}
			
			client_print( id, print_center, "** You are gagged from%s chat! **", bTeam ? " team" : "" );
			
			return PLUGIN_HANDLED;
		}
	}
	
	return PLUGIN_CONTINUE;
}

public CmdGagPlayer( const id, const iLevel, const iCid )
{
	if( !cmd_access( id, iLevel, iCid, 2 ) )
	{
		console_print( id, "Flags: a - Chat | b - Team Chat | c - Voice communications" );
		return PLUGIN_HANDLED;
	}
	
	new szArg[ 32 ];
	read_argv( 1, szArg, 31 );
	
	new iPlayer = cmd_target( id, szArg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS );
	
	if( !iPlayer )
	{
		return PLUGIN_HANDLED;
	}
	
	new szName[ 20 ];
	get_user_name( iPlayer, szName, 19 );
	
	if( TrieKeyExists( g_tArrayPos, g_szAuthid[ iPlayer ] ) )
	{
		console_print( id, "User ^"%s^" is already gagged!", szName );
		return PLUGIN_HANDLED;
	}
	
	get_pcvar_string( g_pCvarDefaultFlags, szArg, charsmax( szArg ) );
	new iFlags = read_flags( szArg );
	
	new iTimeUnit = GetTimeUnit( );
	new iMaxTime = get_pcvar_num( g_pCvarMaxTime );
	new iGagTime = clamp( get_pcvar_num( g_pCvarDefaultTime ), 1, iMaxTime );
	
	read_argv( 2, szArg, 31 );
	
	if( szArg[ 0 ] ) // No time entered
	{
		if( is_str_num( szArg ) ) // Seconds entered
		{
			iGagTime = min( abs( str_to_num( szArg ) ), iMaxTime );
		}
		else
		{
			console_print( id, "The value must be in seconds!" );
			return PLUGIN_HANDLED;
		}
		
		read_argv( 3, szArg, 31 );
		
		if( szArg[ 0 ] )
		{
			iFlags = read_flags( szArg );
		}
	}
	
	// convert to seconds
	iGagTime *= g_iTimeUnitMult[ iTimeUnit ];
	
	new data[ GagData ];
	data[ GAG_START ] = get_systime( );
	data[ GAG_TIME ]  = iGagTime;
	data[ GAG_FLAGS ] = iFlags;
	copy( data[ GAG_AUTHID ], 34, g_szAuthid[ iPlayer ] );
	
	TrieSetCell( g_tArrayPos, g_szAuthid[ iPlayer ], g_iGagged );
	ArrayPushArray( g_aGagData, data );
	
	new szFrom[ 64 ];
	
	if( iFlags & GAG_CHAT )
	{
		copy( szFrom, 63, "say" );
	}
	
	if( iFlags & GAG_TEAMSAY )
	{
		if( !szFrom[ 0 ] )
			copy( szFrom, 63, "say_team" );
		else
			add( szFrom, 63, " / say_team" );
	}
	
	if( iFlags & GAG_VOICE )
	{
		set_speak( iPlayer, SPEAK_MUTED );
		
		if( !szFrom[ 0 ] )
			copy( szFrom, 63, "voicecomm" );
		else
			add( szFrom, 63, " / voicecomm" );
	}
	
	g_iGagged++;
	
	if( iGagTime > 0 )
	{
		new Float:flGametime = get_gametime( ), Float:flNextThink;
		flNextThink = entity_get_float( g_iThinker, EV_FL_nextthink );
		
		if( !flNextThink || flNextThink > ( flGametime + iGagTime ) )
			entity_set_float( g_iThinker, EV_FL_nextthink, flGametime + iGagTime );
	}
	
	SaveToFile( );
	
	new szInfo[ 32 ], szAdmin[ 20 ];
	get_user_name( id, szAdmin, 19 );
	
	if( iGagTime > 0 )
	{
		new iLen = copy( szInfo, 31, "for " );
		GetTimeLength( iGagTime, szInfo[ iLen ], charsmax( szInfo ) - iLen );
	}
	else
	{
		copy( szInfo, 31, "permanently" );
	}
	
	show_activity( id, szAdmin, "Has gagged %s from speaking %s! (%s)", szName, szInfo, szFrom );
	
	console_print( id, "You have gagged ^"%s^" (%s) !", szName, szFrom );
	
	log_amx( "Gag: ^"%s<%s>^" has gagged ^"%s<%s>^" %s. (%s)", szAdmin, g_szAuthid[ id ], szName, g_szAuthid[ iPlayer ], szInfo, szFrom );
	
	return PLUGIN_HANDLED;
}

public CmdAddGag( const id, const iLevel, const iCid )
{
	if( !cmd_access( id, iLevel, iCid, 2 ) )
	{
		console_print( id, "Flags: a - Chat | b - Team Chat | c - Voice communications" );
		return PLUGIN_HANDLED;
	}
	
	new szArg[ 32 ];
	read_argv( 1, szArg, 31 );
	
	// regular expression for a simple check? meh.
	
	if( szArg[ 9 ] != ':' || !( '0' <= szArg[ 8 ] <= '1' ) || !is_str_num( szArg[ 10 ] ) || !equal( szArg, "STEAM_0:", 8 ) )
	{
		console_print( id, "Invalid SteamID provided (%s). Must be in ^"STEAM_0:X:XXXXX^" format (remember to use quotes!)", szArg );
		return PLUGIN_HANDLED;
	}
	
	new iPlayer = find_player( "c", szArg );
	
	if( is_user_connected( iPlayer ) )
	{
		new szTime[ 12 ], szFlags[ 4 ];
		read_argv( 2, szTime,  charsmax( szTime  ) );
		read_argv( 3, szFlags, charsmax( szFlags ) );
		
		client_cmd( id, "amx_gag #%d ^"%s^" ^"%s^"", get_user_userid( iPlayer ), szTime, szFlags );
		return PLUGIN_HANDLED;
	}
	
	if( TrieKeyExists( g_tArrayPos, szArg ) )
	{
		console_print( id, "This user is already gagged!" );
		return PLUGIN_HANDLED;
	}
	
	new data[ GagData ];
	copy( data[ GAG_AUTHID ], 34, szArg );
	
	get_pcvar_string( g_pCvarDefaultFlags, szArg, charsmax( szArg ) );
	new iFlags = read_flags( szArg );
	
	new iTimeUnit = GetTimeUnit( );
	new iMaxTime = get_pcvar_num( g_pCvarMaxTime );
	new iGagTime = clamp( get_pcvar_num( g_pCvarDefaultTime ), 1, iMaxTime );
	
	read_argv( 2, szArg, 31 );
	
	if( szArg[ 0 ] ) // No time entered
	{
		if( is_str_num( szArg ) ) // Seconds entered
		{
			iGagTime = min( abs( str_to_num( szArg ) ), iMaxTime );
		}
		else
		{
			console_print( id, "The value must be in seconds!" );
			return PLUGIN_HANDLED;
		}
		
		read_argv( 3, szArg, 31 );
		
		if( szArg[ 0 ] )
		{
			iFlags = read_flags( szArg );
		}
	}
	
	// convert to seconds
	iGagTime *= g_iTimeUnitMult[ iTimeUnit ];
	
	data[ GAG_START ] = get_systime( );
	data[ GAG_TIME ]  = iGagTime;
	data[ GAG_FLAGS ] = iFlags;
	
	TrieSetCell( g_tArrayPos, data[ GAG_AUTHID ], g_iGagged );
	ArrayPushArray( g_aGagData, data );
	
	new szFrom[ 64 ];
	
	if( iFlags & GAG_CHAT )
	{
		copy( szFrom, 63, "say" );
	}
	
	if( iFlags & GAG_TEAMSAY )
	{
		if( !szFrom[ 0 ] )
			copy( szFrom, 63, "say_team" );
		else
			add( szFrom, 63, " / say_team" );
	}
	
	if( iFlags & GAG_VOICE )
	{
		if( !szFrom[ 0 ] )
			copy( szFrom, 63, "voicecomm" );
		else
			add( szFrom, 63, " / voicecomm" );
	}
	
	g_iGagged++;
	
	if( iGagTime > 0 )
	{
		new Float:flGametime = get_gametime( ), Float:flNextThink;
		flNextThink = entity_get_float( g_iThinker, EV_FL_nextthink );
		
		if( !flNextThink || flNextThink > ( flGametime + iGagTime ) )
			entity_set_float( g_iThinker, EV_FL_nextthink, flGametime + iGagTime );
	}
	
	SaveToFile( );
	
	new szInfo[ 32 ], szAdmin[ 20 ];
	get_user_name( id, szAdmin, 19 );
	
	if( iGagTime > 0 )
	{
		new iLen = copy( szInfo, 31, "for " );
		GetTimeLength( iGagTime, szInfo[ iLen ], charsmax( szInfo ) - iLen );
	}
	else
	{
		copy( szInfo, 31, "permanently" );
	}
	
	show_activity( id, szAdmin, "Has gagged a non-connected player <%s> from speaking %s! (%s)", data[ GAG_AUTHID ], szInfo, szFrom );
	
	console_print( id, "You have gagged ^"%s^" (%s) !", data[ GAG_AUTHID ], szFrom );
	
	log_amx( "Gag: ^"%s<%s>^" has gagged a non-connected player ^"<%s>^" %s. (%s)", szAdmin, g_szAuthid[ id ], data[ GAG_AUTHID ], szInfo, szFrom );
	
	return PLUGIN_HANDLED;
}

public CmdUnGagPlayer( const id, const iLevel, const iCid )
{
	if( !cmd_access( id, iLevel, iCid, 2 ) )
		return PLUGIN_HANDLED;
	
	new szArg[ 32 ];
	read_argv( 1, szArg, 31 );
	
	if( szArg[ 0 ] == '@' && equali( szArg[ 1 ], "all" ) )
	{
		if( !g_iGagged )
		{
			console_print( id, "No gagged players!" );
			return PLUGIN_HANDLED;
		}
		
		while( g_iGagged ) DeleteGag( 0 ); // Excellent by Exolent
		
		if( entity_get_float( g_iThinker, EV_FL_nextthink ) > 0.0 )
			entity_set_float( g_iThinker, EV_FL_nextthink, 0.0 );
		
		console_print( id, "You have ungagged all players!" );
		
		new szAdmin[ 32 ];
		get_user_name( id, szAdmin, 31 );
		
		show_activity( id, szAdmin, "Has ungagged all players." );
		
		log_amx( "UnGag: ^"%s<%s>^" has ungagged all players.", szAdmin, g_szAuthid[ id ] );
		
		return PLUGIN_HANDLED;
	}
	
	new iPlayer = cmd_target( id, szArg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS );
	new iArrayPos, szName[ 32 ];
	
	if( !iPlayer )
	{
		// Maybe it's a steamid
		
		if( szArg[ 9 ] != ':' || !( '0' <= szArg[ 8 ] <= '1' ) || !is_str_num( szArg[ 10 ] ) || !equal( szArg, "STEAM_0:", 8 ) )
		{
			return PLUGIN_HANDLED;
		}
		
		if( !TrieGetCell( g_tArrayPos, szArg, iArrayPos ) )
		{
			console_print( id, "This steamid is not gagged!" );
			return PLUGIN_HANDLED;
		}
		
		copy( szName, charsmax( szName ), szArg );
	}
	else
	{
		get_user_name( iPlayer, szName, charsmax( szName ) );
		
		if( !TrieGetCell( g_tArrayPos, g_szAuthid[ iPlayer ], iArrayPos ) )
		{
			console_print( id, "User ^"%s^" is not gagged!", szName );
			return PLUGIN_HANDLED;
		}
	}
	
	DeleteGag( iArrayPos );
	
	SaveToFile( );
	
	new szAdmin[ 32 ];
	get_user_name( id, szAdmin, 31 );
	
	show_activity( id, szAdmin, "Has ungagged %s.", szName );
	
	console_print( id, "You have ungagged ^"%s^" !", szName );
	
	log_amx( "UnGag: ^"%s<%s>^" has ungagged ^"%s<%s>^"", szAdmin, g_szAuthid[ id ], szName, g_szAuthid[ iPlayer ] );
	
	return PLUGIN_HANDLED;
}

public CmdGagMenu( const id, const iLevel, const iCid )
{
	if( !cmd_access( id, iLevel, iCid, 1 ) )
	{
		return PLUGIN_HANDLED;
	}
	
	g_iMenuOption[ id ] = 0;
	arrayset( g_iMenuPlayers[ id ], 0, 32 );
	
	DisplayGagMenu( id, g_iMenuPosition[ id ] = 0 );
	
	return PLUGIN_HANDLED;
}

#define PERPAGE 6

public ActionGagMenu( const id, const iKey )
{
	switch( iKey )
	{
		case 6: DisplayGagFlags( id );
		case 7:
		{
			++g_iMenuOption[ id ];
			g_iMenuOption[ id ] %= g_iTotalGagTimes;
			
			DisplayGagMenu( id, g_iMenuPosition[ id ] );
		}
		case 8: DisplayGagMenu( id, ++g_iMenuPosition[ id ] );
		case 9: DisplayGagMenu( id, --g_iMenuPosition[ id ] );
		default:
		{
			new iPlayer = g_iMenuPlayers[ id ][ g_iMenuPosition[ id ] * PERPAGE + iKey ];
			
			if( !g_iMenuOption[ id ] )
				client_cmd( id, "amx_ungag #%i", get_user_userid( iPlayer ) );
			else
			{
				new szFlags[ 4 ];
				get_flags( g_iMenuFlags[ id ], szFlags, 3 );
				
				client_cmd( id, "amx_gag #%i %i %s", get_user_userid( iPlayer ), ArrayGetCell( g_aGagTimes, g_iMenuOption[ id ] ), szFlags );
			}
			
			DisplayGagMenu( id, g_iMenuPosition[ id ] );
		}
	}
}

// I just copied this from AMXX Ban menu, so don't blame me :D
DisplayGagMenu( const id, iPosition )
{
	if( iPosition < 0 )
	{
		arrayset( g_iMenuPlayers[ id ], 0, 32 );
		return;
	}
	
	new iPlayers[ 32 ], iNum, iCount, szMenu[ 512 ], iPlayer, iFlags, szName[ 32 ];
	get_players( iPlayers, iNum, "ch" ); // Ignore bots and hltv
	
	new iStart = iPosition * PERPAGE;
	
	if( iStart >= iNum )
		iStart = iPosition = g_iMenuPosition[ id ] = 0;
	
	new iEnd = iStart + PERPAGE, iKeys = MENU_KEY_0 | MENU_KEY_8;
	new iLen = formatex( szMenu, 511, g_bColorSupported ? "\rGag Menu\R%i/%i^n^n" : "Gag Menu %i/%i^n^n", iPosition + 1, ( ( iNum + PERPAGE - 1 ) / PERPAGE ) );
	
	new bool:bUngag = bool:!g_iMenuOption[ id ];
	
	if( iEnd > iNum ) iEnd = iNum;
	
	for( new i = iStart; i < iEnd; ++i )
	{
		iPlayer = iPlayers[ i ];
		iFlags  = get_user_flags( iPlayer );
		get_user_name( iPlayer, szName, 31 );
		
		if( iPlayer == id || ( iFlags & ADMIN_IMMUNITY ) || bUngag != TrieKeyExists( g_tArrayPos, g_szAuthid[ iPlayer ] ) )
		{
			++iCount;
			
			if( g_bColorSupported )
				iLen += formatex( szMenu[ iLen ], 511 - iLen, "\d%i. %s^n", iCount, szName );
			else
				iLen += formatex( szMenu[ iLen ], 511 - iLen, "#. %s^n", szName );
		}
		else
		{
			iKeys |= ( 1 << iCount );
			++iCount;
			
			iLen += formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "\r%i.\w %s\y%s\r%s^n" : "%i. %s%s%s^n", iCount, szName, TrieKeyExists( g_tArrayPos, g_szAuthid[ iPlayer ] ) ? " GAGGED" : "", ( ~iFlags & ADMIN_USER ? " *" : "" ) );
		}
	}
	
	g_iMenuPlayers[ id ] = iPlayers;
	
	new szFlags[ 4 ];
	get_flags( g_iMenuFlags[ id ], szFlags, 3 );
	
	iLen += formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? ( bUngag ? "^n\d7. Flags: %s" : "^n\r7.\y Flags:\w %s" ) : ( bUngag ? "^n#. Flags: %s" : "^n7. Flags: %s" ), szFlags );
	
	if( !bUngag )
	{
		iKeys |= MENU_KEY_7;
		
		new iGagTime = ArrayGetCell( g_aGagTimes, g_iMenuOption[ id ] );
		
		if( iGagTime )
		{
			new szTime[ 128 ];
			GetTimeLength( iGagTime * g_iTimeUnitMult[ GetTimeUnit( ) ], szTime, charsmax( szTime ) );
			
			iLen += formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r8.\y Time:\w %s^n" : "^n8. Time: %s^n", szTime );
		}
		else
			iLen += copy( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r8.\y Time: Permanent^n" : "^n8. Time: Permanent^n" );
	}
	else
		iLen += copy( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r8.\w Ungag^n" : "^n8. Ungag^n" );
	
	if( iEnd != iNum )
	{
		formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r9.\w More...^n\r0.\w %s" : "^n9. More...^n0. %s", iPosition ? "Back" : "Exit" );
		iKeys |= MENU_KEY_9;
	}
	else
		formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r0.\w %s" : "^n0. %s", iPosition ? "Back" : "Exit" );
	
	show_menu( id, iKeys, szMenu, -1, "Gag Menu" );
}

public ActionGagFlags( const id, const iKey )
{
	switch( iKey )
	{
		case 9: DisplayGagMenu( id, g_iMenuPosition[ id ] );
		default:
		{
			g_iMenuFlags[ id ] ^= ( 1 << iKey );
			
			DisplayGagFlags( id );
		}
	}
}

DisplayGagFlags( const id )
{
	new szMenu[ 512 ];
	new iLen = copy( szMenu, 511, g_bColorSupported ? "\rGag Flags^n^n" : "Gag Flags^n^n" );
	
	if( g_bColorSupported )
	{
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "\r1.\w Chat: %s^n", ( g_iMenuFlags[ id ] & GAG_CHAT ) ? "\yYES" : "\rNO" );
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "\r2.\w TeamSay: %s^n", ( g_iMenuFlags[ id ] & GAG_TEAMSAY ) ? "\yYES" : "\rNO" );
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "\r3.\w Voice: %s^n", ( g_iMenuFlags[ id ] & GAG_VOICE ) ? "\yYES" : "\rNO" );
	}
	else
	{
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "1. Chat: %s^n", ( g_iMenuFlags[ id ] & GAG_CHAT ) ? "YES" : "NO" );
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "2. TeamSay: %s^n", ( g_iMenuFlags[ id ] & GAG_TEAMSAY ) ? "YES" : "NO" );
		iLen += formatex( szMenu[ iLen ], 511 - iLen, "3. Voice: %s^n", ( g_iMenuFlags[ id ] & GAG_VOICE ) ? "YES" : "NO" );
	}
	
	copy( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "^n\r0. \wBack to Gag Menu" : "^n0. Back to Gag Menu" );
	
	show_menu( id, ( MENU_KEY_1 | MENU_KEY_2 | MENU_KEY_3 | MENU_KEY_0 ), szMenu, -1, "Gag Flags" );
}

CheckGagFlag( const id, const iFlag )
{
	new iArrayPos;
	
	if( TrieGetCell( g_tArrayPos, g_szAuthid[ id ], iArrayPos ) )
	{
		new data[ GagData ];
		ArrayGetArray( g_aGagData, iArrayPos, data );
		
		return ( data[ GAG_FLAGS ] & iFlag );
	}
	
	return 0;
}

DeleteGag( const iArrayPos )
{
	new data[ GagData ];
	ArrayGetArray( g_aGagData, iArrayPos, data );
	
	if( data[ GAG_FLAGS ] & GAG_VOICE )
	{
		new iPlayer = find_player( "c", data[ GAG_AUTHID ] );
		if( is_user_connected( iPlayer ) )
			set_speak( iPlayer, SPEAK_NORMAL );
	}
	
	TrieDeleteKey( g_tArrayPos, data[ GAG_AUTHID ] );
	ArrayDeleteItem( g_aGagData, iArrayPos );
	g_iGagged--;
	
	for( new i = iArrayPos; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		TrieSetCell( g_tArrayPos, data[ GAG_AUTHID ], i );
	}
}

LoadFromFile( )
{
	new hFile = fopen( g_szGagFile, "rt" );
	
	if( hFile )
	{
		new szData[ 128 ], szTime[ 16 ], szStart[ 16 ], szFlags[ 4 ];
		new data[ GagData ], iSystime = get_systime( ), iTimeLeft, iShortestTime = 999999;
		new bool:bRemovedGags = false;
		
		while( !feof( hFile ) )
		{
			fgets( hFile, szData, charsmax( szData ) );
			trim( szData );
			
			if( !szData[ 0 ] ) continue;
			
			parse( szData,
				data[ GAG_AUTHID ], charsmax( data[ GAG_AUTHID ] ),
				szTime, charsmax( szTime ),
				szStart, charsmax( szStart ),
				szFlags, charsmax( szFlags )
			);
			
			// remove old gags
			if( contain( szStart, "." ) > 0 ) continue;
			
			data[ GAG_TIME ] = str_to_num( szTime );
			data[ GAG_START ] = str_to_num( szStart );
			data[ GAG_FLAGS ] = read_flags( szFlags );
			
			if( data[ GAG_TIME ] > 0 )
			{
				iTimeLeft = data[ GAG_START ] + data[ GAG_TIME ] - iSystime;
				
				if( iTimeLeft <= 0 )
				{
					bRemovedGags = true;
					continue;
				}
				
				if( iShortestTime > iTimeLeft )
				{
					iShortestTime = iTimeLeft;
				}
			}
			
			TrieSetCell( g_tArrayPos, data[ GAG_AUTHID ], g_iGagged );
			ArrayPushArray( g_aGagData, data );
			g_iGagged++;
		}
		
		fclose( hFile );
		
		if( bRemovedGags )
		{
			SaveToFile( );
		}
		
		if( iShortestTime < 999999 )
		{
			entity_set_float( g_iThinker, EV_FL_nextthink, get_gametime( ) + iShortestTime );
		}
	}
}

SaveToFile( )
{
	new hFile = fopen( g_szGagFile, "wt" );
	
	if( hFile )
	{
		new data[ GagData ], szFlags[ 4 ];
		
		for( new i = 0; i < g_iGagged; i++ )
		{
			ArrayGetArray( g_aGagData, i, data );
			
			get_flags( data[ GAG_FLAGS ], szFlags, charsmax( szFlags ) );
			
			fprintf( hFile, "^"%s^" ^"%i^" ^"%i^" ^"%s^"^n", data[ GAG_AUTHID ], data[ GAG_TIME ], data[ GAG_START ], szFlags );
		}
		
		fclose( hFile );
	}
}

GetTimeUnit( )
{
	new szTimeUnit[ 64 ], iTimeUnit;
	get_pcvar_string( g_pCvarTimeUnit, szTimeUnit, charsmax( szTimeUnit ) );
	
	if( is_str_num( szTimeUnit ) )
	{
		iTimeUnit = get_pcvar_num( g_pCvarTimeUnit );
		
		if( !( 0 <= iTimeUnit < TimeUnit ) )
		{
			iTimeUnit = -1;
		}
	}
	else
	{
		strtolower( szTimeUnit );
		
		if( !TrieGetCell( g_tTimeUnitWords, szTimeUnit, iTimeUnit ) )
		{
			iTimeUnit = -1;
		}
	}
	
	if( iTimeUnit == -1 )
	{
		iTimeUnit = TIMEUNIT_SECONDS;
		
		set_pcvar_num( g_pCvarTimeUnit, TIMEUNIT_SECONDS );
	}
	
	return iTimeUnit;
}

GetTimeLength( iTime, szOutput[ ], iOutputLen )
{
	new szTimes[ TimeUnit ][ 32 ];
	new iUnit, iValue, iTotalDisplay;
	
	for( new i = TimeUnit - 1; i >= 0; i-- )
	{
		iUnit = g_iTimeUnitMult[ i ];
		iValue = iTime / iUnit;
		
		if( iValue )
		{
			formatex( szTimes[ i ], charsmax( szTimes[ ] ), "%d %s", iValue, g_szTimeUnitName[ i ][ iValue != 1 ] );
			
			iTime %= iUnit;
			
			iTotalDisplay++;
		}
	}
	
	new iLen, iTotalLeft = iTotalDisplay;
	szOutput[ 0 ] = 0;
	
	for( new i = TimeUnit - 1; i >= 0; i-- )
	{
		if( szTimes[ i ][ 0 ] )
		{
			iLen += formatex( szOutput[ iLen ], iOutputLen - iLen, "%s%s%s",
				( iTotalDisplay > 2 && iLen ) ? ", " : "",
				( iTotalDisplay > 1 && iTotalLeft == 1 ) ? ( ( iTotalDisplay > 2 ) ? "and " : " and " ) : "",
				szTimes[ i ]
			);
			
			iTotalLeft--;
		}
	}
	
	return iLen
}

GreenPrint( id, iSender, const szRawMessage[ ], any:... )
{
	if( !iSender )
	{
		new iPlayers[ 32 ], iNum;
		get_players( iPlayers, iNum, "ch" );
		
		if( !iNum ) return;
		
		iSender = iPlayers[ 0 ];
	}
	
	new szMessage[ 192 ];
	vformat( szMessage, charsmax( szMessage ), szRawMessage, 4 );
	
	message_begin( id ? MSG_ONE_UNRELIABLE : MSG_BROADCAST, g_iMsgSayText, _, id );
	write_byte( iSender );
	write_string( szMessage );
	message_end( );
}

LoadWhiteLists( )
{
	new szFileName[ 64 ];
	get_configsdir( szFileName, charsmax( szFileName ) );
	add( szFileName, charsmax( szFileName ), "/gag_white_list.ini" );
	
	new hFile = fopen( szFileName, "rt" );
	
	if( hFile )
	{
		// Pattern for patterns:
		// /pattern here/flags
		// /pattern here/flags "normal"
		// /pattern here/flags "team"
		// /pattern here/flags "both"
		// /pattern here/flags "all"
		new szError[ 128 ];
		new Regex:pPatternForPatterns = regex_compile("^^\/.+\/[imsx]*(\s+(^"(normal|team|both|all)^"|(normal|team|both|all)))?$", g_iReturnFromRegex, szError, charsmax( szError ), "i");
		
		if( pPatternForPatterns < REGEX_OK )
		{
			log_amx( "Failed to create pattern for finding patterns: (%d) %s", g_iReturnFromRegex, szError );
			
			fclose( hFile );
			
			return;
		}
		
		new szData[ 64 + MAX_PATTERN_LEN ], iLen;
		new szPattern[ MAX_PATTERN_LEN + 1 ], szFlags[ 5 ];
		new Regex:pPattern, iSayArea;
		new data[ WhiteListData ];
		
		while( !feof( hFile ) )
		{
			iLen = fgets( hFile, szData, charsmax( szData ) ) - trim( szData );
			
			if( !szData[ 0 ] || szData[ 0 ] == ';'
			|| szData[ 0 ] == '/' && szData[ 1 ] == '/'
			|| regex_match_c( szData, pPatternForPatterns, g_iReturnFromRegex ) <= 0 )
			{
				continue;
			}
			
			// set it to have both normal and team say
			iSayArea = 0b11;
			
			while( --iLen >= 0 )
			{
				// found pattern before specific say area
				// assume we're checking in both
				if( szData[ iLen ] == '/' )
				{
					break;
				}
				
				// found the space, so figure out what say area we're checking
				if( szData[ iLen ] == ' ' )
				{
					if( containi( szData[ iLen ], "normal" ) > 0 )
					{
						// set to normal say
						iSayArea = 0b01;
					}
					else if( containi( szData[ iLen ], "team" ) > 0 )
					{
						// set to team say
						iSayArea = 0b10;
					}
					
					szData[ iLen ] = 0;
					
					iLen -= trim( szData );
					
					break;
				}
			}
			
			// find the flags for the pattern
			while( iLen > 0 && szData[ --iLen ] != '/' ) { }
			iLen++;
			
			copy( szPattern, iLen, szData );
			copy( szFlags, charsmax( szFlags ), szData[ iLen ] );
			strtolower( szFlags );
			
			pPattern = regex_compile( szPattern, g_iReturnFromRegex, szError, charsmax( szError ), szFlags );
			
			if( pPattern < REGEX_OK )
			{
				log_amx( "Failed to create pattern ^"%s^": (%d) %s", szPattern, g_iReturnFromRegex, szError );
				continue;
			}
			
			data[ WHITELIST_PATTERN ] = _:pPattern;
			data[ WHITELIST_SAYAREA ] = iSayArea;
			
			ArrayPushArray( g_aWhiteLists, data );
			g_iNumWhiteLists++;
		}
		
		regex_free( pPatternForPatterns );
		
		fclose( hFile );
	}
}