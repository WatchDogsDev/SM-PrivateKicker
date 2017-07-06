#pragma semicolon 1

#define DEBUG

#define PLUGIN_VERSION	"1.2.4 - Debug"

#include <sourcemod>
#define AUTOLOAD_EXTENSIONS
#define REQUIRE_EXTENSIONS
#include <SteamWorks>

bool IsPrivate[MAXPLAYERS + 1];
int iWarnings[MAXPLAYERS + 1];

#if defined DEBUG
char file[PLATFORM_MAX_PATH];
#endif

Handle h_bEnable;
Handle h_bKickFailed;
Handle h_iGameID;
Handle h_sURL;
Handle h_iWarnings;
Handle h_iTimeout;
Handle h_bExcludeAdmins;


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
	
	#if defined DEBUG
		BuildPath(Path_SM, file, sizeof(file), "logs/PrivateKick_Debug.txt");
	#endif
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(IsPrivate[client])
	{
		int iTotalWarnings = GetConVarInt(h_iWarnings);
		
		iWarnings[client]++;
		
		PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public before your next %i spawn(s) you will get kicked.", iTotalWarnings - iWarnings[client]);
		
		if(iWarnings[client] >= iTotalWarnings)
		{
			KickClient(client, "Kicked by server. Your steam profile is private Make it public and rejoin.");
		}
	}
}

public void OnClientDisconnect(int client)
{
	if(!IsFakeClient(client) && IsPrivate[client])
	{
		IsPrivate[client] = false;
		iWarnings[client] = 0;
	}
}

public void OnClientAuthorized(int client, const char[] steamId)
{
	if(GetConVarBool(h_bEnable) && !IsFakeClient(client))
	{
		if (GetConVarBool(h_bExcludeAdmins) && GetUserAdmin(client) != INVALID_ADMIN_ID) 
			return;
		
		SendRequest(client, steamId);
	}
}

public void SendRequest(int client, const char[] steamId)
{
	char sURL[256];
	GetConVarString(h_sURL, sURL, sizeof(sURL));
	
	char gameId[16];
	IntToString(GetConVarInt(h_iGameID), gameId, sizeof(gameId));
	
	char maxTotal[16];
	IntToString(0, maxTotal, sizeof maxTotal);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, GetConVarInt(h_iTimeout));
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "gameId", gameId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "steamId", steamId);
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "maxTotal", maxTotal);
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "maxTotalNo2Weeks", steamId);
	SteamWorks_SetHTTPCallbacks(hRequest, HTTP_RequestComplete);
	SteamWorks_SetHTTPRequestContextValue(hRequest, SteamIdToInt(steamId), GetClientUserId(client));
	SteamWorks_SendHTTPRequest(hRequest);
	
	#if defined DEBUG
		LogToFile(file, "HTTP Request has sent for client %i, UserID: %i, Steam2: %s, GameID: %s, URL: %s", client, GetClientUserId(client), steamId, gameId, sURL);
	#endif
}

public HTTP_RequestComplete(Handle HTTPRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any steamIntId, any userid)
{
	int client = GetClientOfUserId(userid);
	
	#if defined DEBUG
		LogToFile(file, "HTTP Request call back. client %i, UserID: %i", client, userid);
	#endif
	
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
		
		#if defined DEBUG
			LogToFile(file, "HTTP Request call back, connection failed. client %i, UserID: %i, eStatusCode: %d, bRequestSuccessful: %i", client, userid, eStatusCode, bRequestSuccessful);
		#endif
		
		return;
	}
	
	int iBodySize;
	if (SteamWorks_GetHTTPResponseBodySize(HTTPRequest, iBodySize))
	{
		#if defined DEBUG
			LogToFile(file, "HTTP Request call back. client %i, UserID: %i, iBodySize: %i", client, userid, iBodySize);
		#endif
		
		if (iBodySize == 0)
		{
			PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public you will get kicked.");
			IsPrivate[client] = true;
			iWarnings[client] = 0;
			
			#if defined DEBUG
				LogToFile(file, "HTTP Request call back. client %i, UserID: %i, Private detected.", client, userid);
			#endif
			return;
		}
		
		char sBody[256];
		SteamWorks_GetHTTPResponseBodyData(HTTPRequest, sBody, iBodySize);
		
		#if defined DEBUG
			LogToFile(file, "HTTP Request call back. client %i, UserID: %i, sBody: %s", client, userid, sBody);
		#endif
	}
	else 
	{
		#if defined DEBUG
			LogToFile(file, "HTTP Request call back, failed to receive body size. client %i, UserID: %i", client, userid);
		#endif
		
		if(GetConVarBool(h_bKickFailed))
		{
			KickClient(client, "Failed to retrieve profile status.");
		}
		
	}
}

SteamIdToInt(const char[] steamId)
{
    char subinfo[3][16];
    ExplodeString(steamId, ":", subinfo, sizeof subinfo, sizeof subinfo[]);
    return (StringToInt(subinfo[2]) * 2) + StringToInt(subinfo[1]);
}