import type {
  Credentials,
  EmployeePunch,
  GetMyPunchesResponse,
  LoginResponse,
  SaveForbiddenPunchResponse,
  SetStatusResponse,
} from "./types";

type PunchDirection = "in" | "out";

const PORTAL_URL = "https://vtportal.visualtime.net/api/portalsvcx.svc";

export interface Session {
  token: string;
  employeeId: number;
  employeeName: string;
  guid: string;
  cookies: string;
  companyId: string;
  presenceStatus: string;
  lastPunchDirection: string;
  lastPunchDate: Date | null;
}

function generateGuid(): string {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export async function login(credentials: Credentials): Promise<Session> {
  const guid = generateGuid();

  const formData = new FormData();
  formData.append("user", credentials.user);
  formData.append("password", credentials.password);
  formData.append("language", "ENG");
  formData.append("accessFromApp", "false");
  formData.append("appVersion", "3.46.0");
  formData.append("validationCode", "");
  formData.append("timeZone", "Europe/Lisbon");
  formData.append("buttonLogin", "true");

  const response = await fetch(`${PORTAL_URL}/Authenticate`, {
    method: "POST",
    headers: {
      roAuth: guid,
      roCompanyID: credentials.companyId,
      roApp: "VTPortal",
      roSrc: "false",
    },
    body: formData,
  });

  if (!response.ok) {
    throw new Error(`Login failed: ${response.status} ${response.statusText}`);
  }

  // Capture cookies for session continuity
  const setCookies = response.headers.getSetCookie();
  const cookies = setCookies.map((c) => c.split(";")[0]).join("; ");

  const data = (await response.json()) as LoginResponse;

  if (data.d.Status !== 0) {
    throw new Error(`Login failed with status: ${data.d.Status}`);
  }

  const status = data.d.EmployeeStatus;

  let lastPunchDate: Date | null = null;
  if (status.LastPunchDate) {
    const match = status.LastPunchDate.match(/\/Date\((\d+)/);
    if (match?.[1]) {
      lastPunchDate = new Date(parseInt(match[1], 10));
    }
  }

  return {
    token: data.d.Token,
    employeeId: data.d.EmployeeId,
    employeeName: status.EmployeeName,
    guid,
    cookies,
    companyId: credentials.companyId,
    presenceStatus: status.PresenceStatus || "Unknown",
    lastPunchDirection: status.LastPunchDirection || "Unknown",
    lastPunchDate,
  };
}

export async function punch(
  session: Session,
  direction: PunchDirection = "in",
): Promise<{ success: boolean; status: string; direction: string }> {
  const apiDirection = direction === "in" ? "E" : "S";
  const params = new URLSearchParams({
    causeId: "0",
    direction: apiDirection,
    latitude: "-1",
    longitude: "-1",
    identifier: "",
    locationZone: "",
    fullAddress: "",
    reliable: "true",
    nfcTag: "",
    tcType: "",
    reliableZone: "true",
    selectedZone: "-1",
    timeZone: "Europe/Lisbon",
    timestamp: Date.now().toString(),
  });

  const response = await fetch(`${PORTAL_URL}/SetStatus?${params.toString()}`, {
    method: "GET",
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      roAuth: session.guid,
      roToken: session.token,
      roSrc: "false",
      roCompanyID: session.companyId,
      roApp: "VTPortal",
      Cookie: session.cookies,
    },
  });

  if (!response.ok) {
    throw new Error(`Punch failed: ${response.status} ${response.statusText}`);
  }

  const data = (await response.json()) as SetStatusResponse;

  if (data.d.Status !== 0) {
    throw new Error(
      `Punch failed with status: ${data.d.Status} (${data.d.CustomErrorText || "unknown error"})`,
    );
  }

  return {
    success: true,
    status: data.d.PresenceStatus || "Unknown",
    direction: data.d.LastPunchDirection || "Unknown",
  };
}

export async function getMyPunches(
  session: Session,
  date: string, // "DD/MM/YYYY"
): Promise<EmployeePunch[]> {
  const params = new URLSearchParams({
    selectedDate: date,
    timestamp: "0",
    _: Date.now().toString(),
  });

  const response = await fetch(`${PORTAL_URL}/GetMyPunches?${params}`, {
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      roAuth: session.guid,
      roToken: session.token,
      roSrc: "false",
      roCompanyID: session.companyId,
      roApp: "VTPortal",
      Cookie: session.cookies,
    },
  });

  if (!response.ok) {
    throw new Error(
      `GetMyPunches failed: ${response.status} ${response.statusText}`,
    );
  }

  const data = (await response.json()) as GetMyPunchesResponse;
  return data.d.Punches ?? [];
}

async function doSaveForbiddenPunch(
  session: Session,
  punchDateTime: string,
  apiDirection: "E" | "S",
  acceptWarning: boolean,
): Promise<SaveForbiddenPunchResponse> {
  const formData = new FormData();
  formData.append("punchDate", punchDateTime);
  formData.append("idCause", "144"); // PT esquecimento de picagem
  formData.append("comments", "");
  formData.append("direction", apiDirection);
  formData.append("acceptWarning", acceptWarning ? "true" : "false");
  formData.append("tcType", "0");

  const response = await fetch(`${PORTAL_URL}/SaveRequestForbiddenPunch`, {
    method: "POST",
    headers: {
      roAuth: session.guid,
      roToken: session.token,
      roSrc: "false",
      roCompanyID: session.companyId,
      roApp: "VTPortal",
      Cookie: session.cookies,
    },
    body: formData,
  });

  if (!response.ok) {
    throw new Error(
      `SaveForbiddenPunch failed: ${response.status} ${response.statusText}`,
    );
  }

  return (await response.json()) as SaveForbiddenPunchResponse;
}

export async function saveForbiddenPunch(
  session: Session,
  punchDateTime: string, // "YYYY-MM-DD HH:MM"
  direction: PunchDirection,
): Promise<{ requestId: number }> {
  const apiDirection = direction === "in" ? "E" : "S";
  let data = await doSaveForbiddenPunch(
    session,
    punchDateTime,
    apiDirection,
    false,
  );

  // A negative status indicates a warning (e.g. nearby punch exists).
  // Retry with acceptWarning: true to confirm and push through.
  if (!data.d.Result && data.d.Status < 0) {
    data = await doSaveForbiddenPunch(
      session,
      punchDateTime,
      apiDirection,
      true,
    );
  }

  if (!data.d.Result) {
    throw new Error(
      `SaveForbiddenPunch rejected (status: ${data.d.Status})\n  StatusErrorMsg: ${JSON.stringify(data.d.StatusErrorMsg)}\n  StatusInfoMsg:  ${JSON.stringify(data.d.StatusInfoMsg)}\n  Full response:  ${JSON.stringify(data.d)}`,
    );
  }

  return { requestId: data.d.RequestId };
}
