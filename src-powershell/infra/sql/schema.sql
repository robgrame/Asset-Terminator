-- Asset-Terminator PowerShell parity — current-state store schema (Azure SQL).
-- Parity with AssetTerminator.Infrastructure.Data.AssetTerminatorDbContext.
-- Managed by hand (no EF migrations); idempotent so it can be re-run safely.
--
-- Holds mutable, queryable state only. The immutable audit lives in Blob WORM
-- storage (see AT.Infrastructure/Audit.psm1), never here.

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID(N'dbo.DecommissionRequests', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DecommissionRequests
    (
        RequestId        NVARCHAR(200)  NOT NULL CONSTRAINT PK_DecommissionRequests PRIMARY KEY,
        CorrelationId    NVARCHAR(64)   NOT NULL,
        AssetId          NVARCHAR(200)  NULL,
        DeviceName       NVARCHAR(256)  NULL,
        SerialNumber     NVARCHAR(128)  NULL,
        PrimaryUserUpn   NVARCHAR(256)  NULL,
        DeviceType       NVARCHAR(32)   NULL,
        AssetCategory    NVARCHAR(32)   NULL,
        DispositionType  NVARCHAR(32)   NULL,
        TicketNumber     NVARCHAR(128)  NULL,
        Requestor        NVARCHAR(256)  NULL,
        DryRun           BIT            NOT NULL CONSTRAINT DF_Requests_DryRun DEFAULT(0),
        State            NVARCHAR(32)   NOT NULL,
        SlaState         NVARCHAR(32)   NULL,
        CreatedAtUtc     DATETIMEOFFSET NOT NULL,
        LastUpdatedAtUtc DATETIMEOFFSET NOT NULL,
        DueAtUtc         DATETIMEOFFSET NULL,
        RequestJson      NVARCHAR(MAX)  NULL,
        DeviceContextJson NVARCHAR(MAX) NULL
    );
    CREATE INDEX IX_DecommissionRequests_CorrelationId ON dbo.DecommissionRequests (CorrelationId);
    CREATE INDEX IX_DecommissionRequests_State         ON dbo.DecommissionRequests (State);
END
GO

-- Idempotent column add for pre-existing deployments.
IF COL_LENGTH(N'dbo.DecommissionRequests', N'DeviceContextJson') IS NULL
    ALTER TABLE dbo.DecommissionRequests ADD DeviceContextJson NVARCHAR(MAX) NULL;
GO

IF OBJECT_ID(N'dbo.DecommissionActions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.DecommissionActions
    (
        Id             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_DecommissionActions PRIMARY KEY,
        RequestId      NVARCHAR(200) NOT NULL,
        Target         NVARCHAR(32)  NULL,
        [Action]       NVARCHAR(64)  NULL,
        Status         NVARCHAR(32)  NOT NULL,
        Attempts       INT           NOT NULL CONSTRAINT DF_Actions_Attempts DEFAULT(0),
        FinalOutcome   NVARCHAR(64)  NULL,
        LastUpdatedUtc DATETIMEOFFSET NULL,
        NextPollUtc    DATETIMEOFFSET NULL,
        CorrelationRef NVARCHAR(200)  NULL,
        CONSTRAINT FK_Actions_Requests FOREIGN KEY (RequestId)
            REFERENCES dbo.DecommissionRequests (RequestId) ON DELETE CASCADE
    );
    CREATE INDEX IX_DecommissionActions_Request_Target ON dbo.DecommissionActions (RequestId, Target);
END
GO

IF OBJECT_ID(N'dbo.GuardrailOverrides', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.GuardrailOverrides
    (
        Id           BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_GuardrailOverrides PRIMARY KEY,
        RequestId    NVARCHAR(200)  NOT NULL,
        ApproverUpn  NVARCHAR(256)  NOT NULL,
        Reason       NVARCHAR(2000) NOT NULL,
        GuardrailIds NVARCHAR(MAX)  NULL,   -- JSON array of guardrail ids
        GrantedAtUtc DATETIMEOFFSET NOT NULL
    );
    CREATE INDEX IX_GuardrailOverrides_RequestId ON dbo.GuardrailOverrides (RequestId);
END
GO
