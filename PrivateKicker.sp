#pragma semicolon 1

#define PLUGIN_VERSION	"1.2.2 - Debug"

#include <sourcemod>
#include <SteamWorks>

bool IsPrivate[MAXPLAYERS + 1];
int iWarnings[MAXPLAYERS + 1];
int iChecks[MAXPLAYERS + 1];
int iMaxChecks = 10;
char steamId[MAXPLAYERS + 1][32];
char gameId[16];
char file[PLATFORM_MAX_PATH];

Handle h_bEnable;
Handle h_bKickFailed;
Handle h_iGameID;
Handle h_sURL;
Handle h_iWarnings;
Handle h_iTimeout;
Handle h_bExcludeAdmins;

Handle CheckTimers[MAXPLAYERS + 1];


public Plugin myinfo = 
{
	name = "Private Kicker",
	author = "[W]atch [D]ogs, Soroush Falahati",
	description = "Kicks the players without public profile after X count of warnings",
	version = PLUGIN_VERSION
}

public void OnPluginStart()
{
	h_bEnable = CreateConVar("sm_private_kick_enable", "1", "Enable / Disable the plugin", _, true, 0.0, true, 1.0);
	h_iGameID = CreateConVar("sm_private_kick_gameid", "730", "Steam's Store id of the game you want us to check against?");
	h_bKickFailed = CreateConVar("sm_private_kick_failed", "0", "Enable / Disable kicking client if didn't receive response", _, true, 0.0, true, 1.0);
	h_sURL = CreateConVar("sm_private_kick_url", "", "Address of the PHP file responsible for getting user profile status.");
	h_iWarnings = CreateConVar("sm_private_kick_warnings", "5", "How many warnings should plugin warn before kicking client", _, true, 1.0);
	h_iTimeout = CreateConVar("sm_private_kick_timeout","10","Maximum number of seconds till we consider the requesting connection timed out?",_, true, 0.0, true, 300.0);
	h_bExcludeAdmins = CreateConVar("sm_private_kick_exclude_admins", "1", "Enable / Disable exclude private checking for admins", _, true, 0.0, true, 1.0);
	
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	AutoExecConfig(true, "Private_Kicker");
	
	BuildPath(Path_SM, file, sizeof(file), "logs/PrivateKick_Debug.txt");
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(IsPrivate[client])
	{
		PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public before your next spawn you will get kicked.");
		iWarnings[client]++;
		
		if(iWarnings[client] >= GetConVarInt(h_iWarnings))
		{
			KickClient(client, "Kicked by server. Your steam profile is private Make it public and rejoin.");
		}
	}
}

public void OnClientDisconnect(int client)
{
	if(GetConVarBool(h_bEnable) && !IsFakeClient(client))
	{
		steamId[client] = NULL_STRING;
		iChecks[client] = 0;
		
		if(CheckTimers[client] != INVALID_HANDLE)
		{
			KillTimer(CheckTimers[client]);
			CheckTimers[client] = INVALID_HANDLE;
		}
		
		if(IsPrivate[client])
		{
			IsPrivate[client] = false;
			iWarnings[client] = 0;
		}
	}
}

public void OnClientPostAdminCheck(int client)
{
	if(GetConVarBool(h_bEnable) && !IsFakeClient(client))
	{
		if (GetConVarBool(h_bExcludeAdmins) && GetUserAdmin(client) != INVALID_ADMIN_ID) 
			return;
		
		IntToString(GetConVarInt(h_iGameID), gameId, sizeof(gameId));
		
		if(GetClientAuthId(client, AuthId_Steam2, steamId[client], 32))
		{
			SendRequest(client, steamId[client]);
		}
		else
		{
			LogToFile(file, "Error in client %i (UserID: %i) - (SteamID: %s) auth. Checking again...", client, GetClientUserId(client), steamID);
			CheckTimers[client] = CreateTimer(10.0, Timer_CheckIDAgain, client, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public Action Timer_CheckIDAgain(Handle timer, int client)
{
	iChecks[client]++;
	
	if(iChecks[client] >= iMaxChecks) 
	{
		LogError("Private-Kicker: Failed to retrieve %N's SteamID after %i tries.", client, iMaxChecks);
		if(GetConVarBool(h_bKickFailed)) 
		{
			KickClient(client, "Failed to retrieve your SteamID.");
		}
		iChecks[client] = 0;
		return Plugin_Stop;
	}
	
	if(GetClientAuthId(client, AuthId_Steam2, steamId[client], 32))
	{
		SendRequest(client, steamId[client]);
		iChecks[client] = 0;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

public void SendRequest(int client, char[] steamID)
{
	char sURL[256];
	GetConVarString(h_sURL, sURL, sizeof(sURL));

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, GetConVarInt(h_iTimeout));
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "gameId", gameId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "steamId", steamID);
	SteamWorks_SetHTTPCallbacks(hRequest, HTTP_RequestComplete);
	SteamWorks_SetHTTPRequestContextValue(hRequest, GetClientUserId(client));
	SteamWorks_SendHTTPRequest(hRequest);
	
	LogToFile(file, "HTTP Request has sent for client %i, UserID: %i, Steam2: %s, GameID: %s, URL: %s", client, GetClientUserId(client), steamID, gameId, sURL);
}

public HTTP_RequestComplete(Handle HTTPRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any userid)
{
	int client = GetClientOfUserId(userid);
	LogToFile(file, "HTTP Request call back. client %i, UserID: %i", client, userid);
	
	if(!bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		if(bRequestSuccessful)
		{
			CloseHandle(HTTPRequest);
		}
		if (GetConVarBool(h_bKickFailed))
		{	
			KickClient(client, "Failed to retrieve profile status.");
		}
		LogError("Private-Kicker: Failed to retrieve user's profile status (HTTP status: %d)", eStatusCode);
		return;
	}
	
	int iBodySize;
	if (SteamWorks_GetHTTPResponseBodySize(HTTPRequest, iBodySize))
	{
		LogToFile(file, "HTTP Request call back. client %i, UserID: %i, iBodySize: %i", client, userid, iBodySize);
		if (iBodySize == 0)
		{
			PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public you will get kicked.");
			IsPrivate[client] = true;
			iWarnings[client] = 0;
			LogToFile(file, "HTTP Request call back. client %i, UserID: %i, Is Private = true", client, userid);
		}
	}
}
