#if defined _amx_gag_included
	#endinput
#endif

#define _amx_gag_included

enum ( <<= 1 )
{
	GAG_CHAT = 1,
	GAG_TEAMSAY,
	GAG_VOICE
};

#define GAG_ALLCHAT ( GAG_CHAT | GAG_TEAMSAY )
#define GAG_ALL ( GAG_CHAT | GAG_TEAMSAY | GAG_VOICE )

native is_user_gagged( id );
native set_user_gagged( id, bool:bGagged = true, seconds = 0, save = 0, flags = GAG_ALL );
native get_gagtime( id );

native gag_check( const auth[ ] );
native gag_add( const auth[ ], seconds = 0, save = 0, flags = GAG_ALL );
native gag_remove( const auth[ ] );
