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

/**
 * Checks whether a player is gagged or not
 * 
 * @param		id - The player index
 * 
 * @return		True if gagged, false otherwise
 */
native bool:is_user_gagged( id );

/**
 * Sets a player's gagged status
 * 
 * @param		id - The player index
 * @param		bGagged - true gags player, false ungags player
 * @param		seconds - Time in seconds to gag player
 * @param		save - Whether or not this gag should be saved in file/SQL
 * @param		flags - What flags to be used when gagging the player
 * 
 * @return		1 on success, 0 on failure
 * 
 * @note		seconds, save, and flags parameters are ignored when bGagged is false
 */
native set_user_gagged( id, bool:bGagged = true, seconds = 0, save = 0, flags = GAG_ALL );

/**
 * Gets how many seconds are left until a player is ungagged
 * 
 * @param		id - The player index
 * 
 * @return		Seconds left in gag time, 0 if not gagged
 */
native get_gagtime( id );

/**
 * Checks if a given SteamID is gagged
 * 
 * @param		auth - The SteamID string to check
 * 
 * @return		1 if gagged, 0 otherwise
 */
native gag_check( const auth[ ] );

/**
 * Adds a SteamID to the gag list
 * 
 * @param		auth - The SteamID to gag
 * @param		seconds - How long to gag the SteamID, 0 is permanent
 * @param		save - 1 saves in SQL/File, 0 does not
 * @param		flags - What flags to be used when gagging the SteamID
 * 
 * @return		1 on success, 0 on failure
 */
native gag_add( const auth[ ], seconds = 0, save = 0, flags = GAG_ALL );

/**
 * Removes a SteamID from the gag list
 * 
 * @param		auth - The SteamID to remove
 * 
 * @return		1 on success, 0 on failure
 */
native gag_remove( const auth[ ] );
