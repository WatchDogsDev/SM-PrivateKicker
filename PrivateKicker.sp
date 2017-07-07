#pragma semicolon 1

#define DEBUG

#define PLUGIN_VERSION	"1.2.6 - Debug"

#include <sourcemod>
#define AUTOLOAD_EXTENSIONS
#define REQUIRE_EXTENSIONS
#include <SteamWorks>

bool b_IsPrivate[MAXPLAYERS + 1];
int iWarnings[MAXPLAYERS + 1];
int iChecks[MAXPLAYERS + 1];
int iMaxChecks;

char steamId[MAXPLAYERS + 1][32];

#if defined DEBUG
char file[PLATFORM_MAX_PATH];
#endif

Handle h_bEnable;
Handle h_bKickFailed;
Handle h_sURL;
Handle h_iWarnings;
Handle h_iTimeout;
Handle h_bExcludeAdmins;
Handle h_iRetries;

Handle CheckTimers[MAXPLAYERS + 1];


public Plugin myinfo = 
{
	name = "Private Kicker", 
	author = "[W]atch [D]ogs, Soroush Falahati, Special thanks to arne1288", 
	description = "Kicks the players without public profile after X count of warnings", 
	version = PLUGIN_VERSION
}

public void OnPluginStart()
{
	h_bEnable = CreateConVar("sm_private_kick_enable", "1", "Enable / Disable the plugin", _, true, 0.0, true, 1.0);
	h_bKickFailed = CreateConVar("sm_private_kick_failed", "0", "Enable / Disable kicking client if didn't receive response", _, true, 0.0, true, 1.0);
	h_sURL = CreateConVar("sm_private_kick_url", "https://steamapi.darkserv.download/public/", "Address of the PHP file responsible for getting user profile status.");
	h_iWarnings = CreateConVar("sm_private_kick_warnings", "5", "How many warnings should plugin warn before kicking client", _, true, 1.0);
	h_iTimeout = CreateConVar("sm_private_kick_timeout", "10", "Maximum number of seconds till we consider the requesting connection timed out?", _, true, 0.0, true, 300.0);
	h_bExcludeAdmins = CreateConVar("sm_private_kick_exclude_admins", "1", "Enable / Disable exclude private checking for admins", _, true, 0.0, true, 1.0);
	h_iRetries = CreateConVar("sm_private_kick_retries", "5", "How many retries should plugin do if player SteamID was unknwon or connection was not successful", _, true, 1.0);
	
	HookConVarChange(h_iRetries, Retries_Change);
	HookEvent("player_spawn", Event_PlayerSpawn);
	
	AutoExecConfig(true, "PrivateKicker");
	
	#if defined DEBUG
	BuildPath(Path_SM, file, sizeof(file), "logs/PrivateKick_Debug.txt");
	#endif
}

public void Retries_Change(Handle convar, const char[] oldValue, const char[] newValue)
{
	iMaxChecks = GetConVarInt(convar);
}

public Action Event_PlayerSpawn(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (b_IsPrivate[client])
	{
		int iTotalWarnings = GetConVarInt(h_iWarnings);
		
		iWarnings[client]++;
		
		PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public before your next %i spawn(s) you will get kicked.", iTotalWarnings - iWarnings[client]);
		
		if (iWarnings[client] >= iTotalWarnings)
		{
			KickClient(client, "Kicked by server. Your steam profile is private Make it public and rejoin.");
		}
	}
}

public void OnClientDisconnect(int client)
{
	if (!IsFakeClient(client))
	{
		steamId[client] = NULL_STRING;
		iChecks[client] = 0;
		
		if (CheckTimers[client] != INVALID_HANDLE)
		{
			KillTimer(CheckTimers[client]);
			CheckTimers[client] = INVALID_HANDLE;
		}
		
		if (b_IsPrivate[client])
		{
			b_IsPrivate[client] = false;
			iWarnings[client] = 0;
		}
	}
}

public void OnClientPostAdminCheck(int client)
{
	if (GetConVarBool(h_bEnable) && !IsFakeClient(client))
	{
		iChecks[client] = 0;
		
		if (GetConVarBool(h_bExcludeAdmins) && GetUserAdmin(client) != INVALID_ADMIN_ID)
			return;
		
		if (GetClientAuthId(client, AuthId_SteamID64, steamId[client], 32))
		{
			SendRequest(client, steamId[client]);
		}
		else
		{
			CheckTimers[client] = CreateTimer(10.0, Timer_CheckIDAgain, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
		}
	}
}

public Action Timer_CheckIDAgain(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	
	iChecks[client]++;
	if (iChecks[client] >= iMaxChecks)
	{
		LogError("Private-Kicker: Failed to retrieve %N's SteamID after %i tries.", client, iMaxChecks);
		if (GetConVarBool(h_bKickFailed))
		{
			KickClient(client, "Failed to retrieve your SteamID.");
		}
		iChecks[client] = 0;
		CheckTimers[client] = INVALID_HANDLE;
		return Plugin_Stop;
	}
	
	if (GetClientAuthId(client, AuthId_SteamID64, steamId[client], 32))
	{
		SendRequest(client, steamId[client]);
		iChecks[client] = 0;
		CheckTimers[client] = INVALID_HANDLE;
		return Plugin_Stop;
	}
	return Plugin_Continue;
}

public void SendRequest(int client, const char[] steamID64)
{
	char sURL[256];
	GetConVarString(h_sURL, sURL, sizeof(sURL));
	
	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sURL);
	SteamWorks_SetHTTPRequestNetworkActivityTimeout(hRequest, GetConVarInt(h_iTimeout));
	SteamWorks_SetHTTPRequestGetOrPostParameter(hRequest, "steamID64", steamID64);
	SteamWorks_SetHTTPCallbacks(hRequest, HTTP_RequestComplete);
	SteamWorks_SetHTTPRequestContextValue(hRequest, GetClientUserId(client));
	SteamWorks_SendHTTPRequest(hRequest);
	
	#if defined DEBUG
	LogToFile(file, "HTTP Request has sent for client %i, UserID: %i, SteamID64: %s, URL: %s", client, GetClientUserId(client), steamID64, sURL);
	#endif
}

public HTTP_RequestComplete(Handle HTTPRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, any userid)
{
	int client = GetClientOfUserId(userid);
	
	#if defined DEBUG
	LogToFile(file, "HTTP Request call back. client %i, UserID: %i", client, userid);
	#endif
	
	if (!bRequestSuccessful || (eStatusCode != k_EHTTPStatusCode202Accepted && eStatusCode != k_EHTTPStatusCode406NotAcceptable))
	{
		if (GetConVarBool(h_bKickFailed))
		{
			KickClient(client, "Failed to retrieve profile status.");
		}
		else
		{
			CreateTimer(60.0, Timer_SendRequestAgain, userid, TIMER_FLAG_NO_MAPCHANGE);
		}
		LogError("Private-Kicker: Failed to retrieve user's profile status (HTTP status: %d)", eStatusCode);
		
		#if defined DEBUG
			LogToFile(file, "HTTP Request call back, connection failed. client %i, UserID: %i, eStatusCode: %d, bRequestSuccessful: %i", client, userid, eStatusCode, bRequestSuccessful);
		#endif
		
		return;
	}
	
	if (eStatusCode == k_EHTTPStatusCode202Accepted)
	{
		#if defined DEBUG
		LogToFile(file, "HTTP Request call back. client %i, UserID: %i, Public account detected.", client, userid);
		#endif
		
		return;
	}
	if (eStatusCode == k_EHTTPStatusCode406NotAcceptable)
	{
		PrintToChat(client, "[SM] WARNING! Your steam profile is private. If you don't make it public you will get kicked.");
		b_IsPrivate[client] = true;
		iWarnings[client] = 0;
		
		#if defined DEBUG
		LogToFile(file, "HTTP Request call back. client %i, UserID: %i, Private account detected.", client, userid);
		#endif
		
		return;
	}
} 

public Action Timer_SendRequestAgain(Handle timer, any userid)
{
	int client = GetClientOfUserId(userid);
	SendRequest(client, steamId[client]);
}