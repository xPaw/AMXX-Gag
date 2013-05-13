#include < amxmodx >
#include < amxmisc >
#include < engine >
#include < sqlx >

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
	GAG_STEAMID[ 35 ],
	GAG_TIME,
	GAG_START,
	GAG_FLAGS,
	GAG_SAVE,
	GAG_NOTIFY
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

new const DATETIME_FORMAT[ ] = "%Y-%m-%d %H:%M:%S";
const DATE_SIZE = 20;

new Array:g_aGagTimes;
new Array:g_aGagData;
new Trie:g_tArrayPos;
new Trie:g_tTimeUnitWords;

new g_iGagged;
new g_iThinker;
new g_iTotalGagTimes;
new g_iMsgSayText;

new g_szSteamID[ MAX_PLAYERS + 1 ][ 35 ];
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
new g_pCvarSQL;
new g_pCvarSQLHost;
new g_pCvarSQLUser;
new g_pCvarSQLPass;
new g_pCvarSQLDb;

new bool:g_bUsingSQL = false;
new Handle:g_hSqlTuple;

new szQuery[ 1024 ];

public plugin_init( )
{
	register_plugin( "AMXX Gag", "1.5.0", "xPaw & Exolent" );
	
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
	g_pCvarSQL          = register_cvar( "amx_gag_sql",           "0"     );
	g_pCvarSQLHost      = register_cvar( "amx_gag_sql_host",      ""      );
	g_pCvarSQLUser      = register_cvar( "amx_gag_sql_user",      ""      );
	g_pCvarSQLPass      = register_cvar( "amx_gag_sql_pass",      ""      );
	g_pCvarSQLDb        = register_cvar( "amx_gag_sql_db",        ""      );
	
	g_tArrayPos       = TrieCreate( );
	g_aGagTimes       = ArrayCreate( );
	g_aGagData        = ArrayCreate( GagData );
	g_bColorSupported = bool:colored_menus( );
	g_iMsgSayText     = get_user_msgid( "SayText" );
	
	// Let words work with the time unit cvar
	g_tTimeUnitWords = TrieCreate( );
	
	for( new i = 0; i < TimeUnit; i++ )
	{
		TrieSetCell( g_tTimeUnitWords, g_szTimeUnitName[ i ][ 0 ], i );
		TrieSetCell( g_tTimeUnitWords, g_szTimeUnitName[ i ][ 1 ], i );
	}
	
	// This is used for ungag in the menu
	ArrayPushCell( g_aGagTimes, 0 );
	
	// Gag times for the gag menu (amx_gagmenu)
	// Default values: 60 300 600 1800 3600 7200 86400
	new const iDefaultTimes[ ] = { 60, 300, 600, 1800, 3600, 7200, 86400, 0 };
	
	// Load up standart times
	for( new i = 0; i < sizeof( iDefaultTimes ); i++ )
	{
		ArrayPushCell( g_aGagTimes, iDefaultTimes[ i ] );
	}
	
	g_iTotalGagTimes = sizeof( iDefaultTimes ) + 1;
	
	// Set up entity-thinker
	new const szClassName[ ] = "gag_thinker";
	
	g_iThinker = create_entity( "info_target" );
	entity_set_string( g_iThinker, EV_SZ_classname, szClassName );
	
	register_think( szClassName, "FwdThink" );
	
	// Load gags from file
	get_datadir( g_szGagFile, charsmax( g_szGagFile ) );
	add( g_szGagFile, charsmax( g_szGagFile ), "/gags.txt" );
	
	// Set server's SteamID to "SERVER"
	copy( g_szSteamID[ 0 ], charsmax( g_szSteamID[ ] ), "SERVER" );
}

public plugin_natives( )
{
	register_library( "amx_gag" );
	
	register_native( "is_user_gagged" , "_is_user_gagged"  );
	register_native( "set_user_gagged", "_set_user_gagged" );
	register_native( "get_gagtime"    , "_get_gagtime"     );
	
	register_native( "gag_check" , "_gag_check"  );
	register_native( "gag_add"   , "_gag_add"    );
	register_native( "gag_remove", "_gag_remove" );
}

public _is_user_gagged( iPlugin, iParams )
{
	new iPlayer = get_param( 1 );
	
	return ( is_user_connected( iPlayer ) && TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) );
}

public _set_user_gagged( iPlugin, iParams )
{
	new iPlayer  = get_param( 1 );
	new bGagged  = get_param( 2 );
	new iSeconds = get_param( 3 );
	new bSave    = get_param( 4 );
	new iFlags   = get_param( 5 );
	
	if( !is_user_connected( iPlayer ) )
	{
		return 0;
	}
	
	if( bGagged )
	{
		if( TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) )
		{
			return 0;
		}
		
		GagPlayer( 0, iPlayer, g_szSteamID[ iPlayer ], iSeconds, iFlags, bSave, 0 );
	}
	else
	{
		new iArrayPos;
		
		if( !TrieGetCell( g_tArrayPos, g_szSteamID[ iPlayer ], iArrayPos ) )
		{
			return 0;
		}
		
		new data[ GagData ];
		ArrayGetArray( g_aGagData, iArrayPos, data );
		
		DeleteGag( iArrayPos );
	
		if( !g_bUsingSQL && data[ GAG_SAVE ] )
		{
			SaveToFile( );
		}
	}
	
	return 1;
}

public _get_gagtime( iPlugin, iParams )
{
	new iPlayer = get_param( 1 );
	new iTime = 0;
	
	if( is_user_connected( iPlayer ) )
	{
		new iArrayPos;
		
		if( TrieGetCell( g_tArrayPos, g_szSteamID[ iPlayer ], iArrayPos ) )
		{
			new data[ GagData ];
			ArrayGetArray( g_aGagData, iArrayPos, data );
			
			if( data[ GAG_TIME ] > 0 )
			{
				iTime = data[ GAG_START ] + data[ GAG_TIME ] - get_systime( );
			}
		}
	}
	
	return iTime;
}

public _gag_check( iPlugin, iParams )
{
	new szSteamID[ 35 ];
	get_string( 1, szSteamID, charsmax( szSteamID ) );
	
	return _:TrieKeyExists( g_tArrayPos, szSteamID );
}

public _gag_add( iPlugin, iParams )
{
	new szSteamID[ 35 ];
	get_string( 1, szSteamID, charsmax( szSteamID ) );
	
	if( TrieKeyExists( g_tArrayPos, szSteamID ) )
	{
		return 0;
	}
	
	new iSeconds = get_param( 2 );
	new bSave    = get_param( 3 );
	new iFlags   = get_param( 4 );
	
	GagPlayer( 0, 0, szSteamID, iSeconds, iFlags, bSave, 0 );
	
	return 1;
}

public _gag_remove( iPlugin, iParams )
{
	new szSteamID[ 35 ];
	get_string( 1, szSteamID, charsmax( szSteamID ) );
	
	new iArrayPos;
	
	if( !TrieGetCell( g_tArrayPos, szSteamID, iArrayPos ) )
	{
		return 0;
	}
	
	DeleteGag( iArrayPos );
	
	return 1;
}

public plugin_cfg( )
{
	// Check SQL
	InitSQL( );
	
	if( !g_bUsingSQL )
	{
		// If not using SQL, load from file
		LoadFromFile( );
	}
}

InitSQL( )
{
	// Init SQL after configs were executed
	if( get_pcvar_num( g_pCvarSQL ) )
	{
		new szHost[ 64 ], szUser[ 64 ], szPass[ 64 ], szDb[ 64 ];
		get_pcvar_string( g_pCvarSQLHost, szHost, charsmax( szHost ) );
		get_pcvar_string( g_pCvarSQLUser, szUser, charsmax( szUser ) );
		get_pcvar_string( g_pCvarSQLPass, szPass, charsmax( szPass ) );
		get_pcvar_string( g_pCvarSQLDb,   szDb,   charsmax( szDb   ) );
		
		g_hSqlTuple = SQL_MakeDbTuple( szHost, szUser, szPass, szDb );
		
		if( g_hSqlTuple == Empty_Handle ) return;
		
		// TABLE STRUCTURE
		// admin_name VARCHAR(32) NOT NULL
		// admin_steamid VARCHAR(35) NOT NULL
		// admin_ip VARCHAR(15) NOT NULL
		// player_name VARCHAR(32) NOT NULL
		// player_steamid VARCHAR(35) NOT NULL PRIMARY KEY
		// player_ip VARCHAR(15) NOT NULL
		// date_gagged DATETIME NOT NULL
		// date_ungag DATETIME NOT NULL
		// gag_seconds INT NOT NULL
		// gag_flags VARCHAR(3) NOT NULL
		
		new iError, szError[ 128 ];
		new Handle:hDb = SQL_Connect( g_hSqlTuple, iError, szError, charsmax( szError ) );
		
		if( hDb == Empty_Handle )
		{
			log_amx( "Failed to connect to database: (%d) %s", iError, szError );
			return;
		}
		
		new Handle:hQuery = SQL_PrepareQuery( hDb, "CREATE TABLE IF NOT EXISTS gagged_players (\
			admin_name VARCHAR(32) NOT NULL,\
			admin_steamid VARCHAR(35) NOT NULL,\
			admin_ip VARCHAR(15) NOT NULL,\
			player_name VARCHAR(32) NOT NULL,\
			player_steamid VARCHAR(35) NOT NULL PRIMARY KEY,\
			player_ip VARCHAR(15) NOT NULL,\
			date_gagged DATETIME NOT NULL,\
			date_ungag DATETIME NOT NULL,\
			gag_seconds INT NOT NULL,\
			gag_flags VARCHAR(3) NOT NULL);" );
		
		if( !SQL_Execute( hQuery ) )
		{
			SQL_QueryError( hQuery, szError, charsmax( szError ) );
			log_amx( "Failed create table query: %s", szError );
		}
		else
		{
			SQL_FreeHandle( hQuery );
			
			new szDate[ DATE_SIZE ];
			get_time( DATETIME_FORMAT, szDate, charsmax( szDate ) );
			
			// Load all users
			hQuery = SQL_PrepareQuery( hDb, "SELECT * FROM gagged_players WHERE date_ungag > '%s';", szDate );
			
			if( !SQL_Execute( hQuery ) )
			{
				SQL_QueryError( hQuery, szError, charsmax( szError ) );
				log_amx( "Failed load gags query: %s", szError );
			}
			else
			{
				g_bUsingSQL = true;
				
				if( SQL_NumResults( hQuery ) )
				{
					new iSystime = get_systime( );
					new iShortestTime = 999999;
					
					new data[ GagData ];
					new szFlags[ 4 ];
					new iTimeLeft;
					
					data[ GAG_SAVE   ] = 1;
					data[ GAG_NOTIFY ] = 1;
					
					new iFieldSteamID = SQL_FieldNameToNum( hQuery, "player_steamid" );
					new iFieldDateGagged = SQL_FieldNameToNum( hQuery, "date_gagged" );
					new iFieldGagTime = SQL_FieldNameToNum( hQuery, "gag_seconds" );
					new iFieldGagFlags = SQL_FieldNameToNum( hQuery, "gag_flags" );
					
					while( SQL_MoreResults( hQuery ) )
					{
						SQL_ReadResult( hQuery, iFieldSteamID, data[ GAG_STEAMID ], charsmax( data[ GAG_STEAMID ] ) );
						SQL_ReadResult( hQuery, iFieldDateGagged, szDate, charsmax( szDate ) );
						data[ GAG_TIME ] = SQL_ReadResult( hQuery, iFieldGagTime );
						SQL_ReadResult( hQuery, iFieldGagFlags, szFlags, charsmax( szFlags ) );
						
						data[ GAG_START ] = strtotime( szDate );
						data[ GAG_FLAGS ] = read_flags( szFlags );
						
						if( data[ GAG_TIME ] > 0 )
						{
							iTimeLeft = data[ GAG_START ] + data[ GAG_TIME ] - iSystime;
							
							if( iShortestTime > iTimeLeft )
							{
								iShortestTime = iTimeLeft;
							}
						}
						
						ArrayPushArray( g_aGagData, data );
						TrieSetCell( g_tArrayPos, data[ GAG_STEAMID ], g_iGagged );
						g_iGagged++;
						
						SQL_NextRow( hQuery );
					}
					
					if( iShortestTime < 999999 )
					{
						entity_set_float( g_iThinker, EV_FL_nextthink, get_gametime( ) + iShortestTime );
					}
				}
			}
		}
		
		SQL_FreeHandle( hQuery );
		SQL_FreeHandle( hDb );
	}
}

public plugin_end( )
{
	TrieDestroy( g_tArrayPos );
	ArrayDestroy( g_aGagData );
	ArrayDestroy( g_aGagTimes );
	TrieDestroy( g_tTimeUnitWords );
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
	
	// This is used for ungag in the menu
	ArrayPushCell( g_aGagTimes, 0 );
	g_iTotalGagTimes = 1;
	
	// Get max time allowed
	new iTimeLimit = get_pcvar_num( g_pCvarMaxTime );
	
	new szBuffer[ 32 ], iTime;
	for( new i = 1; i < iArgs; i++ )
	{
		read_argv( i, szBuffer, 31 );
		
		if( !is_str_num( szBuffer ) )
		{
			server_print( "[AMXX GAG] Time must be an integer! (%s)", szBuffer );
			continue;
		}
		
		iTime = str_to_num( szBuffer );
		
		if( iTime < 0 )
		{
			server_print( "[AMXX GAG] Time must be a positive integer! (%d)", iTime );
			continue;
		}
		
		if( 0 < iTimeLimit < iTime )
		{
			server_print( "[AMXX GAG] Time more then %d is not allowed! (%d)", iTimeLimit, iTime );
			continue;
		}
		
		ArrayPushCell( g_aGagTimes, iTime );
		g_iTotalGagTimes++;
	}
	
	return PLUGIN_HANDLED;
}

public client_putinserver( id )
{
	if( CheckGagFlag( id, GAG_VOICE ) )
	{
		set_speak( id, SPEAK_MUTED );
	}
	
	// Default flags are "abc"
	g_iMenuFlags[ id ] = GAG_CHAT | GAG_TEAMSAY | GAG_VOICE;
}

public client_authorized( id )
{
	get_user_authid( id, g_szSteamID[ id ], 34 );
}

public client_disconnect( id )
{
	if( TrieKeyExists( g_tArrayPos, g_szSteamID[ id ] ) )
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
					GreenPrint( iPlayer, id, "^4[AMXX GAG]^1 Gagged player ^"^3%s^1<^4%s^1>^" has disconnected!", szName, g_szSteamID[ id ] );
				}
				else
				{
					client_print( iPlayer, print_chat, "[AMXX GAG] Gagged player ^"%s<%s>^" has disconnected!", szName, g_szSteamID[ id ] );
				}
			}
		}
	}
	
	g_szSteamID[ id ][ 0 ] = '^0';
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
	{
		return;
	}
	
	new iSystime = get_systime( );
	new bool:bRemovedGags = false;
	
	new bool:bUsingSQL = g_bUsingSQL;
	new Array:aRemoveSteamIDs, iNumRemoveSteamIDs;
	
	if( bUsingSQL )
	{
		aRemoveSteamIDs = ArrayCreate( 35 );
		g_bUsingSQL = false;
	}
	
	new data[ GagData ], id, szName[ 32 ];
	for( new i = 0; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		
		if( data[ GAG_TIME ] > 0 && ( data[ GAG_START ] + data[ GAG_TIME ] ) <= iSystime )
		{
			id = find_player( "c", data[ GAG_STEAMID ] );
			
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
					GreenPrint( 0, 0, "^4[AMXX GAG]^1 SteamID ^"^3%s^1^" is no longer gagged", data[ GAG_STEAMID ] );
				}
				else
				{
					client_print( 0, print_chat, "[AMXX GAG] SteamID ^"%s^" is no longer gagged", data[ GAG_STEAMID ] );
				}
			}
			
			DeleteGag( i-- );
			
			bRemovedGags = true;
			
			if( bUsingSQL )
			{
				ArrayPushString( aRemoveSteamIDs, data[ GAG_STEAMID ] );
				iNumRemoveSteamIDs++;
			}
		}
	}
	
	if( !bUsingSQL )
	{
		if( bRemovedGags )
		{
			SaveToFile( );
		}
	}
	else
	{
		if( iNumRemoveSteamIDs )
		{
			new szNext[ 64 ], iNextLen, iDefaultLen, iLen = iDefaultLen = copy( szQuery, charsmax( szQuery ), "DELETE FROM gagged_players WHERE " );
			
			for( new i = 0; i < iNumRemoveSteamIDs; i++ )
			{
				ArrayGetString( aRemoveSteamIDs, i, data[ GAG_STEAMID ], charsmax( data[ GAG_STEAMID ] ) );
				
				iNextLen = formatex( szNext, charsmax( szNext ), "%splayer_steamid = ^"%s^"", i ? " OR " : "", data[ GAG_STEAMID ] );
				
				if( ( iLen + iNextLen + 1 ) > charsmax( szQuery ) )
				{
					szQuery[ iLen++ ] = ';'
					szQuery[ iLen ] = 0;
					
					SQL_ThreadQuery( g_hSqlTuple, "HandleDefaultQuery", szQuery );
					
					szQuery[ ( iLen = iDefaultLen ) ] = 0;
				}
				
				iLen += copy( szQuery[ iLen ], charsmax( szQuery ) - iLen, szNext );
			}
			
			szQuery[ iLen++ ] = ';';
			szQuery[ iLen ] = 0;
			
			SQL_ThreadQuery( g_hSqlTuple, "HandleDefaultQuery", szQuery );
		}
		
		ArrayDestroy( aRemoveSteamIDs );
		
		g_bUsingSQL = true;
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
{
	return CheckSay( id, 0 );
}

public CmdTeamSay( const id )
{
	return CheckSay( id, 1 );
}

CheckSay( const id, const bIsTeam )
{
	new iArrayPos;
	
	if( TrieGetCell( g_tArrayPos, g_szSteamID[ id ], iArrayPos ) )
	{
		new data[ GagData ];
		ArrayGetArray( g_aGagData, iArrayPos, data );
		
		new const iFlags[ ] = { GAG_CHAT, GAG_TEAMSAY };
		
		if( data[ GAG_FLAGS ] & iFlags[ bIsTeam ] )
		{
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
			
			client_print( id, print_center, "** You are gagged from%s chat! **", bIsTeam ? " team" : "" );
			
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
	
	if( TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) )
	{
		console_print( id, "User ^"%s^" is already gagged!", szName );
		return PLUGIN_HANDLED;
	}
	
	new iFlags;
	new iGagTime = -1;
	
	read_argv( 2, szArg, 31 );
	
	if( szArg[ 0 ] ) // No time entered
	{
		if( is_str_num( szArg ) ) // Seconds entered
		{
			iGagTime = abs( str_to_num( szArg ) );
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
	
	GagPlayer( id, iPlayer, g_szSteamID[ iPlayer ], iGagTime, iFlags );
	
	return PLUGIN_HANDLED;
}

GagPlayer( id, iPlayer, const szPlayerSteamID[ ], iGagTime, iFlags, bSave=1, bNotify=1 )
{
	new iMaxTime = get_pcvar_num( g_pCvarMaxTime );
	
	if( iGagTime == -1 )
	{
		iGagTime = clamp( get_pcvar_num( g_pCvarDefaultTime ), 0, iMaxTime );
	}
	
	if( iGagTime )
	{
		new iTimeUnit = GetTimeUnit( );
		
		iGagTime = clamp( iGagTime, 1, iMaxTime ) * g_iTimeUnitMult[ iTimeUnit ];
	}
	
	if( !iFlags )
	{
		new szFlags[ 27 ];
		get_pcvar_string( g_pCvarDefaultFlags, szFlags, charsmax( szFlags ) );
		
		iFlags = read_flags( szFlags );
	}
	
	new data[ GagData ];
	data[ GAG_START ]  = get_systime( );
	data[ GAG_TIME ]   = iGagTime;
	data[ GAG_FLAGS ]  = iFlags;
	data[ GAG_SAVE ]   = bSave;
	data[ GAG_NOTIFY ] = bNotify;
	copy( data[ GAG_STEAMID ], 34, szPlayerSteamID );
	
	TrieSetCell( g_tArrayPos, szPlayerSteamID, g_iGagged );
	ArrayPushArray( g_aGagData, data );
	
	g_iGagged++;
	
	if( iGagTime > 0 )
	{
		new Float:flGametime = get_gametime( ), Float:flNextThink;
		flNextThink = entity_get_float( g_iThinker, EV_FL_nextthink );
		
		if( !flNextThink || flNextThink > ( flGametime + iGagTime ) )
		{
			entity_set_float( g_iThinker, EV_FL_nextthink, flGametime + iGagTime );
		}
	}
	
	if( bSave )
	{
		if( g_bUsingSQL )
		{
			new szPlayerName[ 32 ], szPlayerIP[ 32 ];
			
			if( iPlayer )
			{
				get_user_name( iPlayer, szPlayerName, charsmax( szPlayerName ) );
				get_user_ip( iPlayer, szPlayerIP, charsmax( szPlayerIP ), 1 );
			}
			else
			{
				szPlayerName[ 0 ] = szPlayerIP[ 0 ] = '?';
			}
			
			AddGag( id, g_szSteamID[ iPlayer ], szPlayerName, szPlayerIP, iGagTime, iFlags );
		}
		else
		{
			SaveToFile( );
		}
	}
	
	if( bNotify )
	{
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
		
		new szName[ 64 ];
		
		if( iPlayer )
		{
			get_user_name( iPlayer, szName, 19 );
		}
		else
		{
			formatex( szName, charsmax( szName ), "a non-connected player <%s>", szPlayerSteamID );
		}
		
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
		
		log_amx( "Gag: ^"%s<%s>^" has gagged ^"%s<%s>^" %s. (%s)", szAdmin, g_szSteamID[ id ], szName, szPlayerSteamID, szInfo, szFrom );
	}
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
	
	if( !IsValidSteamID( szArg ) )
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
	
	if( GetAccessBySteamID( szArg ) & ADMIN_IMMUNITY )
	{
		console_print( id, "This user has immunity!" );
		return PLUGIN_HANDLED;
	}
	
	new data[ GagData ];
	copy( data[ GAG_STEAMID ], 34, szArg );
	
	get_pcvar_string( g_pCvarDefaultFlags, szArg, charsmax( szArg ) );
	new iFlags = read_flags( szArg );
	
	new iMaxTime = get_pcvar_num( g_pCvarMaxTime );
	new iGagTime = clamp( get_pcvar_num( g_pCvarDefaultTime ), 0, iMaxTime );
	
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
	
	new iTimeUnit = GetTimeUnit( );
	
	// convert to seconds
	iGagTime *= g_iTimeUnitMult[ iTimeUnit ];
	
	data[ GAG_START ] = get_systime( );
	data[ GAG_TIME ]  = iGagTime;
	data[ GAG_FLAGS ] = iFlags;
	
	TrieSetCell( g_tArrayPos, data[ GAG_STEAMID ], g_iGagged );
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
	
	if( g_bUsingSQL )
	{
		AddGag( id, data[ GAG_STEAMID ], "?", "?", iGagTime, iFlags );
	}
	else
	{
		SaveToFile( );
	}
	
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
	
	show_activity( id, szAdmin, "Has gagged a non-connected player <%s> from speaking %s! (%s)", data[ GAG_STEAMID ], szInfo, szFrom );
	
	console_print( id, "You have gagged ^"%s^" (%s) !", data[ GAG_STEAMID ], szFrom );
	
	log_amx( "Gag: ^"%s<%s>^" has gagged a non-connected player ^"<%s>^" %s. (%s)", szAdmin, g_szSteamID[ id ], data[ GAG_STEAMID ], szInfo, szFrom );
	
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
		
		DeleteAllGags( );
		
		if( entity_get_float( g_iThinker, EV_FL_nextthink ) > 0.0 )
			entity_set_float( g_iThinker, EV_FL_nextthink, 0.0 );
		
		console_print( id, "You have ungagged all players!" );
		
		new szAdmin[ 32 ];
		get_user_name( id, szAdmin, 31 );
		
		show_activity( id, szAdmin, "Has ungagged all players." );
		
		log_amx( "UnGag: ^"%s<%s>^" has ungagged all players.", szAdmin, g_szSteamID[ id ] );
		
		return PLUGIN_HANDLED;
	}
	
	new iPlayer = cmd_target( id, szArg, CMDTARGET_NO_BOTS );
	new iArrayPos, szName[ 32 ];
	
	if( !iPlayer )
	{
		// Maybe it's a steamid
		
		if( !IsValidSteamID( szArg ) )
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
		
		if( !TrieGetCell( g_tArrayPos, g_szSteamID[ iPlayer ], iArrayPos ) )
		{
			console_print( id, "User ^"%s^" is not gagged!", szName );
			return PLUGIN_HANDLED;
		}
	}
	
	DeleteGag( iArrayPos );
	
	if( !g_bUsingSQL )
	{
		SaveToFile( );
	}
	
	new szAdmin[ 32 ];
	get_user_name( id, szAdmin, 31 );
	
	show_activity( id, szAdmin, "Has ungagged %s.", szName );
	
	console_print( id, "You have ungagged ^"%s^" !", szName );
	
	log_amx( "UnGag: ^"%s<%s>^" has ungagged ^"%s<%s>^"", szAdmin, g_szSteamID[ id ], szName, g_szSteamID[ iPlayer ] );
	
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
			
			if( is_user_connected( iPlayer ) )
			{
				if( !g_iMenuOption[ id ] )
				{
					new iArrayPos;
					
					if( TrieGetCell( g_tArrayPos, g_szSteamID[ iPlayer ], iArrayPos ) )
					{
						DeleteGag( iArrayPos );
						
						if( !g_bUsingSQL )
						{
							SaveToFile( );
						}
						
						new szName[ 32 ];
						get_user_name( iPlayer, szName, 31 );
						
						new szAdmin[ 32 ];
						get_user_name( id, szAdmin, 31 );
						
						show_activity( id, szAdmin, "Has ungagged %s.", szName );
						
						console_print( id, "You have ungagged ^"%s^" !", szName );
						
						log_amx( "UnGag: ^"%s<%s>^" has ungagged ^"%s<%s>^"", szAdmin, g_szSteamID[ id ], szName, g_szSteamID[ iPlayer ] );
					}
				}
				else if( !TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) )
				{
					GagPlayer( id, iPlayer, g_szSteamID[ iPlayer ], ArrayGetCell( g_aGagTimes, g_iMenuOption[ id ] ), g_iMenuFlags[ id ] );
				}
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
	new iLen = formatex( szMenu, 511, g_bColorSupported ? "\rGag Menu\R%d/%d^n^n" : "Gag Menu %d/%d^n^n", iPosition + 1, ( ( iNum + PERPAGE - 1 ) / PERPAGE ) );
	
	new bool:bUngag = bool:!g_iMenuOption[ id ];
	
	if( iEnd > iNum ) iEnd = iNum;
	
	for( new i = iStart; i < iEnd; ++i )
	{
		iPlayer = iPlayers[ i ];
		iFlags  = get_user_flags( iPlayer );
		get_user_name( iPlayer, szName, 31 );
		
		if( iPlayer == id || ( iFlags & ADMIN_IMMUNITY ) || bUngag != TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) )
		{
			++iCount;
			
			if( g_bColorSupported )
				iLen += formatex( szMenu[ iLen ], 511 - iLen, "\d%d. %s^n", iCount, szName );
			else
				iLen += formatex( szMenu[ iLen ], 511 - iLen, "#. %s^n", szName );
		}
		else
		{
			iKeys |= ( 1 << iCount );
			++iCount;
			
			iLen += formatex( szMenu[ iLen ], 511 - iLen, g_bColorSupported ? "\r%d.\w %s\y%s\r%s^n" : "%d. %s%s%s^n", iCount, szName, TrieKeyExists( g_tArrayPos, g_szSteamID[ iPlayer ] ) ? " GAGGED" : "", ( ~iFlags & ADMIN_USER ? " *" : "" ) );
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
	
	if( TrieGetCell( g_tArrayPos, g_szSteamID[ id ], iArrayPos ) )
	{
		new data[ GagData ];
		ArrayGetArray( g_aGagData, iArrayPos, data );
		
		return ( data[ GAG_FLAGS ] & iFlag );
	}
	
	return 0;
}

DeleteAllGags( )
{
	new data[ GagData ];
	new iPlayer;
	
	for( new i = 0; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		
		iPlayer = find_player( "c", data[ GAG_STEAMID ] );
		
		if( is_user_connected( iPlayer ) )
		{
			set_speak( iPlayer, SPEAK_NORMAL );
		}
	}
	
	ArrayClear( g_aGagData );
	TrieClear( g_tArrayPos );
	
	g_iGagged = 0;
	
	if( g_bUsingSQL )
	{
		SQL_ThreadQuery( g_hSqlTuple, "HandleDefaultQuery", "TRUNCATE TABLE gagged_players" );
	}
}

DeleteGag( const iArrayPos )
{
	new data[ GagData ];
	ArrayGetArray( g_aGagData, iArrayPos, data );
	
	if( data[ GAG_FLAGS ] & GAG_VOICE )
	{
		new iPlayer = find_player( "c", data[ GAG_STEAMID ] );
		
		if( is_user_connected( iPlayer ) )
		{
			set_speak( iPlayer, SPEAK_NORMAL );
		}
	}
	
	TrieDeleteKey( g_tArrayPos, data[ GAG_STEAMID ] );
	ArrayDeleteItem( g_aGagData, iArrayPos );
	
	g_iGagged--;
	
	for( new i = iArrayPos; i < g_iGagged; i++ )
	{
		ArrayGetArray( g_aGagData, i, data );
		TrieSetCell( g_tArrayPos, data[ GAG_STEAMID ], i );
	}
	
	if( g_bUsingSQL && data[ GAG_SAVE ] )
	{
		formatex( szQuery, charsmax( szQuery ), "DELETE FROM gagged_players WHERE player_steamid = '%s'", data[ GAG_STEAMID ] );
		
		SQL_ThreadQuery( g_hSqlTuple, "HandleDefaultQuery", szQuery );
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
		
		data[ GAG_SAVE   ] = 1;
		data[ GAG_NOTIFY ] = 1;
		
		while( !feof( hFile ) )
		{
			fgets( hFile, szData, charsmax( szData ) );
			trim( szData );
			
			if( !szData[ 0 ] )
			{
				continue;
			}
			
			parse( szData,
				data[ GAG_STEAMID ], charsmax( data[ GAG_STEAMID ] ),
				szTime, charsmax( szTime ),
				szStart, charsmax( szStart ),
				szFlags, charsmax( szFlags )
			);
			
			// Remove old gags
			if( contain( szStart, "." ) > 0 )
			{
				continue;
			}
			
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
			
			TrieSetCell( g_tArrayPos, data[ GAG_STEAMID ], g_iGagged );
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
			
			if( data[ GAG_SAVE ] )
			{
				get_flags( data[ GAG_FLAGS ], szFlags, charsmax( szFlags ) );
				
				fprintf( hFile, "^"%s^" ^"%d^" ^"%d^" ^"%s^"^n", data[ GAG_STEAMID ], data[ GAG_TIME ], data[ GAG_START ], szFlags );
			}
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

bool:IsValidSteamID( const szSteamID[ ] )
{
	// STEAM_0:(0|1):\d+
	// 012345678    90
	
	// 0-7 = STEAM_0:
	// 8 = 0 or 1
	// 9 = :
	// 10+ = integer
	
	return ( ( '0' <= szSteamID[ 8 ] <= '1' ) && szSteamID[ 9 ] == ':' && equal( szSteamID, "STEAM_0:", 8 ) && is_str_num( szSteamID[ 10 ] ) );
}

GetAccessBySteamID( const szSteamID[ ] )
{
	new szAuthData[ 44 ], iCount = admins_num( );
	
	for( new i; i < iCount; i++ )
	{
		if( admins_lookup( i, AdminProp_Flags ) & FLAG_AUTHID )
		{
			admins_lookup( i, AdminProp_Auth, szAuthData, charsmax( szAuthData ) );
			
			if( equal( szAuthData, szSteamID ) )
			{
				return admins_lookup( i, AdminProp_Access );
			}
		}
	}
	
	return 0;
}

strtotime( const string[ ] )
{
	new szTemp[ 32 ];
	new szYear[ 5 ], szMonth[ 3 ], szDay[ 3 ], szHour[ 3 ], szMinute[ 3 ], szSecond[ 3 ];
	strtok( string, szYear,   charsmax( szYear   ), szTemp,   charsmax( szTemp   ), '-' );
	strtok( szTemp, szMonth,  charsmax( szMonth  ), szTemp,   charsmax( szTemp   ), '-' );
	strtok( szTemp, szDay,    charsmax( szDay    ), szTemp,   charsmax( szTemp   ), ' ' );
	strtok( szTemp, szHour,   charsmax( szHour   ), szTemp,   charsmax( szTemp   ), ':' );
	strtok( szTemp, szMinute, charsmax( szMinute ), szSecond, charsmax( szSecond ), ':' );
	
	return TimeToUnix( str_to_num( szYear ), str_to_num( szMonth ), str_to_num( szDay ), str_to_num( szHour ), str_to_num( szMinute ), str_to_num( szSecond ) );
}

AddGag( admin, const szPlayerSteamID[ ], const szPlayerName[ ], const szPlayerIP[ ], iGagTime, iFlags )
{
	new szAdminName[ 32 ], szAdminIP[ 16 ];
	
	if( admin )
	{
		get_user_name( admin, szAdminName, charsmax( szAdminName ) );
	}
	else
	{
		copy( szAdminName, charsmax( szAdminName ), "SERVER" );
	}
	
	get_user_ip( admin, szAdminIP, charsmax( szAdminIP ), 1 );
	
	new szDateNow[ DATE_SIZE ], szDateUngag[ DATE_SIZE ];
	get_time( DATETIME_FORMAT, szDateNow, charsmax( szDateNow ) );
	format_time( szDateUngag, charsmax( szDateUngag ), DATETIME_FORMAT, get_systime( ) + iGagTime );
	
	new szFlags[ 4 ];
	get_flags( iFlags, szFlags, charsmax( szFlags ) );
	
	formatex( szQuery, charsmax( szQuery ), "REPLACE INTO gagged_players \
		(admin_name, admin_steamid, admin_ip, player_name, player_steamid, player_ip, date_gagged, date_ungag, gag_seconds, gag_flags) \
		VALUES \
		(^"%s^", ^"%s^", ^"%s^", ^"%s^", ^"%s^", ^"%s^", ^"%s^", ^"%s^", %d, ^"%s^")",\
		szAdminName,  g_szSteamID[ admin ], szAdminIP,\
		szPlayerName, szPlayerSteamID       , szPlayerIP,\
		szDateNow, szDateUngag, iGagTime, szFlags );
	
	SQL_ThreadQuery( g_hSqlTuple, "HandleDefaultQuery", szQuery );
}

public HandleDefaultQuery( iFailState, Handle:hQuery, szError[ ], iError, iData[ ], iDataSize, Float:flQueueTime )
{
	if( iFailState != TQUERY_SUCCESS )
	{
		switch( iFailState )
		{
			case TQUERY_CONNECT_FAILED: log_amx( "Failed to connect to database: (%d) %s", iError, szError );
			case TQUERY_QUERY_FAILED:   log_amx( "Failed to execute query: (%d) %s", iError, szError );
		}
	}
}

// CODE BELOW FROM BUGSY'S UNIX TIME INCLUDE
//

new const YearSeconds[ 2 ] =
{
	31536000,	//Normal year
	31622400 	//Leap year
};

new const MonthSeconds[ 12 ] =
{
	2678400, //January	31 
	2419200, //February	28
	2678400, //March	31
	2592000, //April	30
	2678400, //May		31
	2592000, //June		30
	2678400, //July		31
	2678400, //August	31
	2592000, //September	30
	2678400, //October	31
	2592000, //November	30
	2678400  //December	31
};

const DaySeconds = 86400;
const HourSeconds = 3600;
const MinuteSeconds = 60;

TimeToUnix( const iYear, const iMonth, const iDay, const iHour, const iMinute, const iSecond )
{
	new i, iTimeStamp;

	for( i = 1970; i < iYear; i++ )
		iTimeStamp += YearSeconds[ IsLeapYear( i ) ];

	for( i = 1; i < iMonth; i++ )
		iTimeStamp += SecondsInMonth( iYear, i );

	iTimeStamp += ( ( iDay - 1 ) * DaySeconds );
	iTimeStamp += ( iHour * HourSeconds );
	iTimeStamp += ( iMinute * MinuteSeconds );
	iTimeStamp += iSecond;

	return iTimeStamp;
}

SecondsInMonth( const iYear , const iMonth ) 
{
	return ( ( IsLeapYear( iYear ) && ( iMonth == 2 ) ) ? ( MonthSeconds[ iMonth - 1 ] + DaySeconds ) : MonthSeconds[ iMonth - 1 ] );
}

IsLeapYear( const iYear ) 
{
	return ( ( ( iYear % 4 ) == 0) && ( ( ( iYear % 100 ) != 0) || ( ( iYear % 400 ) == 0 ) ) );
}
