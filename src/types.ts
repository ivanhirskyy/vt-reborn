// API Response Types

export interface LoginResponse {
  d: {
    Token: string;
    EmployeeId: number;
    UserId: number;
    Status: number;
    EmployeeStatus: {
      EmployeeName: string;
      LastPunchDate: string;
      LastPunchDirection: "In" | "Out";
      PresenceStatus: string;
      ServerDate: string;
    };
    ServerTimezone: string;
  };
}

export interface SetStatusResponse {
  d: {
    Status: number;
    CustomErrorText: string;
    Result: boolean;
    PresenceStatus?: string;
    LastPunchDirection?: string;
    EmployeeName?: string;
  };
}

export interface EmployeePunch {
  ActualType: number; // 1=in, 2=out
  DateTime: string; // "/Date(timestamp+offset)/"
  ID: number;
  Type: number; // 1=in, 2=out
  TypeData: number;
  RelatedInfo: string;
}

export interface GetMyPunchesResponse {
  d: {
    Punches: EmployeePunch[];
    Status: number;
  };
}

export interface SaveForbiddenPunchResponse {
  d: {
    PunchWithoutRequest: boolean;
    RequestId: number;
    Result: boolean;
    Status: number;
    StatusErrorMsg: string;
    StatusInfoMsg: string | null;
  };
}

// Config Types

export interface ScheduledPunch {
  time: string; // "07:00"
  type: "in" | "out";
}

export interface Config {
  timezone: string;
  jitter?: number; // max jitter in minutes (default: 5)
  punches: ScheduledPunch[];
}

// State Types

export interface State {
  lastPunch?: {
    type: "in" | "out";
    timestamp: string;
  };
}

// Auth credentials from env

export interface Credentials {
  user: string;
  password: string;
  companyId: string;
}
