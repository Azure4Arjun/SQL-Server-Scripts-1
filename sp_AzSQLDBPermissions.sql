/*********************************************************************************************
sp_AzSQLDBPermissions V1.0
Kenneth Fisher


**************************************************
**************************************************
**************************************************
Be careful with any code you find on the internet. 
In particular with this code. I expect it to work  
ok but it is in beta and will probably be buggy.
**************************************************
**************************************************
**************************************************



http://www.sqlstudies.com
 
This stored procedure returns 3 data sets.  The first dataset is the list of database
principals, the second is role membership, and the third is object and database level
permissions.
    
The final 2 columns of each query are "Un-Do"/"Do" scripts.  For example removing a member
from a role or adding them to a role.  I am fairly confident in the role scripts, however, 
the scripts in the database principals query and database/object permissions query are 
works in progress.  In particular certificates, keys and column level permissions are not
scripted out.  Also while the scripts have worked flawlessly on the systems I've tested 
them on, these systems are fairly similar when it comes to security so I can't say that 
in a more complicated system there won't be the odd bug.
    
Standard disclaimer: You use scripts off of the web at your own risk.  I fully expect this
     script to work without issue but I've been known to be wrong before.


Removed Parameters:
    @DBName
        Because this is Azure SQL DB it's not possible to run this on any database but the current one.
    @LoginName
        The sysem views sys.server_xxxxxx aren't available so I've removed this.
    
Parameters:
    @Principal
        If NOT NULL then all three queries only pull for that database principal.  @Principal
        is a pattern check.  The queries check for any row where the passed in value exists.
        It uses the pattern '%' + @Principal + '%'
    @Role
        If NOT NULL then the roles query will pull members of the role.  If it is NOT NULL 
        then DB principal and permissions query will pull the principal row for the role 
        and the permissions for the role.  @Role is a pattern check.  The queries check
        for any row where the passed in value exists.  It uses the pattern '%' + @Role +
        '%'
    @Type
        If NOT NULL then all three queries will only pull principals of that type.  
        S = SQL login
        U = Windows login
        G = Windows group
        R = Server role
        C = Login mapped to a certificate
        K = Login mapped to an asymmetric key
    @ObjectName
        If NOT NULL then the third query will display permissions specific to the object 
        specified and the first two queries will display only those users with those specific
        permissions.  Unfortunately at this point only objects in sys.all_objects will work.
        This parameter uses the pattern '%' + @ObjectName + '%'
    @Permission
        If NOT NULL then the third query will display only permissions that match what is in
        the parameter.  The first two queries will display only those users with that specific
        permission.
	@UseLikeSearch
		When this is set to 1 (the default) then the search parameters will use LIKE (and 
		%'s will be added around the @Principal, @Role, @ObjectName, and @LoginName parameters).  
        When set to 0 searchs will use =.
	@IncludeMSShipped
		When this is set to 1 (the default) then all principals will be included.  When set 
		to 0 the fixed server roles and SA and Public principals will be excluded.
	@DropTempTables
		When this is set to 1 (the default) the temp tables used are dropped.  If it's 0
		then the tempt ables are kept for references after the code has finished.
		The temp tables are:
			##DBPrincipals
			##DBRoles 
			##DBPermissions
	@Output
		What type of output is desired.
		Default - Either 'Default' or it doesn't match any of the allowed values then the SP
					will return the standard 3 outputs.
		None - No output at all.  Usually used if you keeping the temp tables to do your own
					reporting.
		CreateOnly - Only return the create scripts where they aren't NULL.
		DropOnly - Only return the drop scripts where they aren't NULL.
		ScriptsOnly - Return drop and create scripts where they aren't NULL.
		Report - Returns one output with one row per principal and a comma delimited list of
					roles the principal is a member of and a comma delimited list of the 
					individual permissions they have.
    @Print
        Defaults to 0, but if a 1 is passed in then the queries are not run but printed
        out instead.  This is primarily for debugging.
    
Data is ordered as follows
    1st result set: DBPrincipal
    2nd result set: RoleName, UserName if the parameter @Role is used else
                    UserName, RoleName
    3rd result set: ObjectName then Grantee_Name if the parameter @ObjectName
                    is used otherwise Grantee_Name, ObjectName
    
-- V1.0
-- 5/14/2019 – Copy sp_DBPermissions to sp_AzSQLDBPermissions
*********************************************************************************************/
    
CREATE OR ALTER PROCEDURE dbo.sp_AzSQLDBPermissions
(
	@Principal sysname = NULL, 
	@Role sysname = NULL, 
	@Type nvarchar(30) = NULL,
	@ObjectName sysname = NULL,
	@Permission sysname = NULL,
    @UseLikeSearch bit = 1,
    @IncludeMSShipped bit = 1,
	@DropTempTables bit = 1,
	@Output varchar(30) = 'Default',
	@Print bit = 0
)
AS
  
SET NOCOUNT ON
    
DECLARE @Collation nvarchar(75) 
SET @Collation = N' COLLATE ' + CAST(SERVERPROPERTY('Collation') AS nvarchar(50))

DECLARE @sql nvarchar(max)
DECLARE @sql2 nvarchar(max)
DECLARE @ObjectList nvarchar(max)
    
DECLARE @LikeOperator nvarchar(4)

IF @UseLikeSearch = 1
	SET @LikeOperator = N'LIKE'
ELSE 
	SET @LikeOperator = N'='
    
IF @UseLikeSearch = 1
BEGIN 
	IF LEN(ISNULL(@Principal,'')) > 0
		SET @Principal = N'%' + @Principal + N'%'
        
	IF LEN(ISNULL(@Role,'')) > 0
		SET @Role = N'%' + @Role + N'%'
    
	IF LEN(ISNULL(@ObjectName,'')) > 0
		SET @ObjectName = N'%' + @ObjectName + N'%'
  
END
  
--=========================================================================
-- Database Principals
SET @sql =   
    N'SELECT DBPrincipals.principal_id AS DBPrincipalId, DBPrincipals.name AS DBPrincipal, DBPrincipals.type, 
       DBPrincipals.type_desc, DBPrincipals.default_schema_name, DBPrincipals.create_date, 
       DBPrincipals.modify_date, DBPrincipals.is_fixed_role, 
       Authorizations.name AS RoleAuthorization, DBPrincipals.sid,  
       CASE WHEN DBPrincipals.is_fixed_role = 0 AND DBPrincipals.name NOT IN (''dbo'',''guest'', ''INFORMATION_SCHEMA'', ''public'', ''sys'') THEN  
				''IF DATABASE_PRINCIPAL_ID('''''' + DBPrincipals.name + '''''') IS NOT NULL '' + 
               ''DROP '' + CASE DBPrincipals.[type] WHEN ''C'' THEN NULL 
                   WHEN ''K'' THEN NULL 
                   WHEN ''R'' THEN ''ROLE'' 
                   WHEN ''A'' THEN ''APPLICATION ROLE''  
                   ELSE ''USER'' END + 
               '' ''+QUOTENAME(DBPrincipals.name' + @Collation + N') + '';'' ELSE NULL END AS DropScript, 
       CASE WHEN DBPrincipals.is_fixed_role = 0 AND DBPrincipals.name NOT IN (''dbo'',''guest'', ''INFORMATION_SCHEMA'', ''public'', ''sys'') THEN  
				''IF DATABASE_PRINCIPAL_ID('''''' + DBPrincipals.name + '''''') IS NULL '' + 
               ''CREATE '' + CASE DBPrincipals.[type] WHEN ''C'' THEN NULL 
                   WHEN ''K'' THEN NULL 
                   WHEN ''R'' THEN ''ROLE'' 
                   WHEN ''A'' THEN ''APPLICATION ROLE'' 
                   ELSE ''USER'' END + 
               '' ''+QUOTENAME(DBPrincipals.name' + @Collation + N') END +  
               CASE WHEN DBPrincipals.[type] = ''R'' THEN 
                   ISNULL('' AUTHORIZATION ''+QUOTENAME(Authorizations.name' + @Collation + N'),'''')  
				   WHEN DBPrincipals.[type] = ''X'' THEN '' FROM EXTERNAL PROVIDER''
                   WHEN DBPrincipals.[type] = ''A'' THEN 
                       ''''  
                   WHEN DBPrincipals.[type] NOT IN (''C'',''K'') THEN 
                       ISNULL('' WITH DEFAULT_SCHEMA =  ''+
                          QUOTENAME(DBPrincipals.default_schema_name' + @Collation + N'),'''') 
               ELSE '''' END +
			   CASE WHEN DBPrincipals.[type] = ''S'' 
					THEN '', PASSWORD = ''''<Insert Strong Password Here>'''' '' ELSE ''''''''  END + 
               '';'' 
           AS CreateScript 
    FROM sys.database_principals DBPrincipals 
    LEFT OUTER JOIN sys.database_principals Authorizations 
       ON DBPrincipals.owning_principal_id = Authorizations.principal_id 
    WHERE 1=1 
       AND DBPrincipals.sid NOT IN (0x00, 0x01) '
    
IF LEN(ISNULL(@Principal,@Role)) > 0 
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND DBPrincipals.name ' + @LikeOperator + N' ' + 
            ISNULL(QUOTENAME(@Principal,N''''),QUOTENAME(@Role,'''')) 
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND DBPrincipals.name ' + @LikeOperator + N' ISNULL(@Principal,@Role) '
    
IF LEN(@Type) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND DBPrincipals.type ' + @LikeOperator + N' ' + QUOTENAME(@Type,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND DBPrincipals.type ' + @LikeOperator + N' @Type'
    
IF LEN(@ObjectName) > 0
    BEGIN
        SET @sql = @sql + NCHAR(13) + 
        N'   AND EXISTS (SELECT 1 ' + NCHAR(13) + 
        N'               FROM sys.all_objects [Objects] ' + NCHAR(13) + 
        N'               INNER JOIN sys.database_permissions Permission ' + NCHAR(13) +  
        N'                   ON Permission.major_id = [Objects].object_id ' + NCHAR(13) + 
        N'               WHERE Permission.major_id = [Objects].object_id ' + NCHAR(13) + 
        N'                 AND Permission.grantee_principal_id = DBPrincipals.principal_id ' + NCHAR(13)
          
        IF @Print = 1
            SET @sql = @sql + N'                 AND [Objects].name ' + @LikeOperator + N' ' + QUOTENAME(@ObjectName,'''') 
        ELSE
            SET @sql = @sql + N'                 AND [Objects].name ' + @LikeOperator + N' @ObjectName'
  
        SET @sql = @sql + N')'
    END
  
IF LEN(@Permission) > 0
    BEGIN
        SET @sql = @sql + NCHAR(13) + 
        N'   AND EXISTS (SELECT 1 ' + NCHAR(13) + 
        N'               FROM sys.database_permissions Permission ' + NCHAR(13) +  
        N'               WHERE Permission.grantee_principal_id = DBPrincipals.principal_id ' + NCHAR(13)
          
        IF @Print = 1
            SET @sql = @sql + N'                 AND Permission.permission_name ' + @LikeOperator + N' ' + QUOTENAME(@Permission,'''') 
        ELSE
            SET @sql = @sql + N'                 AND Permission.permission_name ' + @LikeOperator + N' @Permission'
  
        SET @sql = @sql + N')'
    END

IF @IncludeMSShipped = 0
	SET @sql = @sql + NCHAR(13) + N'  AND DBPrincipals.is_fixed_role = 0 ' + NCHAR(13) + 
				'  AND DBPrincipals.name NOT IN (''dbo'',''public'',''INFORMATION_SCHEMA'',''guest'',''sys'') '

IF @Print = 1
BEGIN
    PRINT N'-- Database Principals'
    PRINT CAST(@sql AS nvarchar(max))
    PRINT '' -- Spacing before the next print
    PRINT ''
END
ELSE
BEGIN
	IF object_id('tempdb..##DBPrincipals') IS NOT NULL
		DROP TABLE ##DBPrincipals

	-- Create temp table to store the data in
	CREATE TABLE ##DBPrincipals (
		DBPrincipalId int NULL,
		DBPrincipal sysname NULL,
		type char(1) NULL,
		type_desc nchar(60) NULL,
		default_schema_name sysname NULL,
		create_date datetime NULL,
		modify_date datetime NULL,
		is_fixed_role bit NULL,
		RoleAuthorization sysname NULL,
		sid varbinary(85) NULL,
		DropScript nvarchar(max) NULL,
		CreateScript nvarchar(max) NULL
		)
    
	SET @sql =  N'INSERT INTO ##DBPrincipals ' + NCHAR(13) + @sql

    EXEC sp_executesql @sql, N'@Principal sysname, @Role sysname, @Type nvarchar(30), 
        @ObjectName sysname, @Permission sysname', 
        @Principal, @Role, @Type, @ObjectName, @Permission
END  
--=========================================================================
-- Database Role Members
SET @sql =  
    N'SELECT Users.principal_id AS UserPrincipalId, Users.name AS UserName, Roles.name AS RoleName, ' + NCHAR(13) + 
    N'   CASE WHEN Users.is_fixed_role = 0 AND Users.name <> ''dbo'' THEN ' + NCHAR(13) + 
    N'   ''EXEC sp_droprolemember @rolename = ''+QUOTENAME(Roles.name' + @Collation + 
                N','''''''')+'', @membername = ''+QUOTENAME(CASE WHEN Users.name = ''dbo'' THEN NULL
                ELSE Users.name END' + @Collation + 
                N','''''''')+'';'' END AS DropScript, ' + NCHAR(13) + 
    N'   CASE WHEN Users.is_fixed_role = 0 AND Users.name <> ''dbo'' THEN ' + NCHAR(13) + 
    N'   ''EXEC sp_addrolemember @rolename = ''+QUOTENAME(Roles.name' + @Collation + 
                N','''''''')+'', @membername = ''+QUOTENAME(CASE WHEN Users.name = ''dbo'' THEN NULL
                ELSE Users.name END' + @Collation + 
                N','''''''')+'';'' END AS AddScript ' + NCHAR(13) + 
    N'FROM sys.database_role_members RoleMembers ' + NCHAR(13) + 
    N'JOIN sys.database_principals Users ' + NCHAR(13) + 
    N'   ON RoleMembers.member_principal_id = Users.principal_id ' + NCHAR(13) + 
    N'JOIN sys.database_principals Roles ' + NCHAR(13) + 
    N'   ON RoleMembers.role_principal_id = Roles.principal_id ' + NCHAR(13) + 
    N'WHERE 1=1 '
        
IF LEN(ISNULL(@Principal,'')) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Users.name ' + @LikeOperator + N' '+QUOTENAME(@Principal,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Users.name ' + @LikeOperator + N' @Principal'
    
IF LEN(ISNULL(@Role,'')) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Roles.name ' + @LikeOperator + N' '+QUOTENAME(@Role,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Roles.name ' + @LikeOperator + N' @Role'
    
IF LEN(@Type) > 0 
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Users.type ' + @LikeOperator + N' ' + QUOTENAME(@Type,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Users.type ' + @LikeOperator + N' @Type'
  
IF LEN(@ObjectName) > 0
    BEGIN
        SET @sql = @sql + NCHAR(13) + 
        N'   AND EXISTS (SELECT 1 ' + NCHAR(13) + 
        N'               FROM sys.all_objects [Objects] ' + NCHAR(13) + 
        N'               INNER JOIN sys.database_permissions Permission ' + NCHAR(13) +  
        N'                   ON Permission.major_id = [Objects].object_id ' + NCHAR(13) + 
        N'               WHERE Permission.major_id = [Objects].object_id ' + NCHAR(13) + 
        N'                 AND Permission.grantee_principal_id = Users.principal_id ' + NCHAR(13)
          
        IF @Print = 1
            SET @sql = @sql + N'                 AND [Objects].name ' + @LikeOperator + N' ' + QUOTENAME(@ObjectName,'''') 
        ELSE
            SET @sql = @sql + N'                 AND [Objects].name ' + @LikeOperator + N' @ObjectName'
  
        SET @sql = @sql + N')'
    END
  
IF LEN(@Permission) > 0
    BEGIN
        SET @sql = @sql + NCHAR(13) + 
        N'   AND EXISTS (SELECT 1 ' + NCHAR(13) + 
        N'               FROM sys.database_permissions Permission ' + NCHAR(13) +  
        N'               WHERE Permission.grantee_principal_id = Users.principal_id ' + NCHAR(13)
          
        IF @Print = 1
            SET @sql = @sql + N'                 AND Permission.permission_name ' + @LikeOperator + N' ' + QUOTENAME(@Permission,'''') 
        ELSE
            SET @sql = @sql + N'                 AND Permission.permission_name ' + @LikeOperator + N' @Permission'
  
        SET @sql = @sql + N')'
    END
  
IF @IncludeMSShipped = 0
	SET @sql = @sql + NCHAR(13) + N'  AND Users.is_fixed_role = 0 ' + NCHAR(13) + 
				'  AND Users.name NOT IN (''dbo'',''public'',''INFORMATION_SCHEMA'',''guest'',''sys'') '

IF @Print = 1
BEGIN
    PRINT N'-- Database Role Members'
    PRINT CAST(@sql AS nvarchar(max))
    PRINT '' -- Spacing before the next print
    PRINT '' 
END
ELSE
BEGIN
	IF object_id('tempdb..##DBRoles') IS NOT NULL
		DROP TABLE ##DBRoles

    -- Create temp table to store the data in
    CREATE TABLE ##DBRoles (
        UserPrincipalId int NULL,
		UserName sysname NULL,
        RoleName sysname NULL,
        DropScript nvarchar(max) NULL,
        AddScript nvarchar(max) NULL
        )

	SET @sql =  'INSERT INTO ##DBRoles ' + NCHAR(13) + @sql
    
    EXEC sp_executesql @sql, N'@Principal sysname, @Role sysname, @Type nvarchar(30), 
        @ObjectName sysname, @Permission sysname', 
        @Principal, @Role, @Type, @ObjectName, @Permission
END
    
--=========================================================================
-- Database & object Permissions
SET @ObjectList =
    N'; WITH ObjectList AS (' + NCHAR(13) + 
    N'   SELECT SCHEMA_NAME(sys.all_objects.schema_id) ' + @Collation + N' AS SchemaName,' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       object_id AS id, ' + NCHAR(13) + 
    N'       ''OBJECT_OR_COLUMN'' AS class_desc,' + NCHAR(13) + 
    N'       ''OBJECT'' AS class ' + NCHAR(13) + 
    N'   FROM sys.all_objects' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT name ' + @Collation + N' AS SchemaName, ' + NCHAR(13) + 
    N'       NULL AS name, ' + NCHAR(13) + 
    N'       schema_id AS id, ' + NCHAR(13) + 
    N'       ''SCHEMA'' AS class_desc,' + NCHAR(13) + 
    N'       ''SCHEMA'' AS class ' + NCHAR(13) + 
    N'   FROM sys.schemas' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       principal_id AS id, ' + NCHAR(13) + 
    N'       ''DATABASE_PRINCIPAL'' AS class_desc,' + NCHAR(13) + 
    N'       CASE type_desc ' + NCHAR(13) + 
    N'           WHEN ''APPLICATION_ROLE'' THEN ''APPLICATION ROLE'' ' + NCHAR(13) + 
    N'           WHEN ''DATABASE_ROLE'' THEN ''ROLE'' ' + NCHAR(13) + 
    N'           ELSE ''USER'' END AS class ' + NCHAR(13) + 
    N'   FROM sys.database_principals' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       assembly_id AS id, ' + NCHAR(13) + 
    N'       ''ASSEMBLY'' AS class_desc,' + NCHAR(13) + 
    N'       ''ASSEMBLY'' AS class ' + NCHAR(13) + 
    N'   FROM sys.assemblies' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) 

SET @ObjectList = @ObjectList + 
    N'   SELECT SCHEMA_NAME(sys.types.schema_id) ' + @Collation + N' AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       user_type_id AS id, ' + NCHAR(13) + 
    N'       ''TYPE'' AS class_desc,' + NCHAR(13) + 
    N'       ''TYPE'' AS class ' + NCHAR(13) + 
    N'   FROM sys.types' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT SCHEMA_NAME(schema_id) ' + @Collation + N' AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       xml_collection_id AS id, ' + NCHAR(13) + 
    N'       ''XML_SCHEMA_COLLECTION'' AS class_desc,' + NCHAR(13) + 
    N'       ''XML SCHEMA COLLECTION'' AS class ' + NCHAR(13) + 
    N'   FROM sys.xml_schema_collections' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       message_type_id AS id, ' + NCHAR(13) + 
    N'       ''MESSAGE_TYPE'' AS class_desc,' + NCHAR(13) + 
    N'       ''MESSAGE TYPE'' AS class ' + NCHAR(13) + 
    N'   FROM sys.service_message_types' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       service_contract_id AS id, ' + NCHAR(13) + 
    N'       ''SERVICE_CONTRACT'' AS class_desc,' + NCHAR(13) + 
    N'       ''CONTRACT'' AS class ' + NCHAR(13) + 
    N'   FROM sys.service_contracts' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       service_id AS id, ' + NCHAR(13) + 
    N'       ''SERVICE'' AS class_desc,' + NCHAR(13) + 
    N'       ''SERVICE'' AS class ' + NCHAR(13) + 
    N'   FROM sys.services' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       remote_service_binding_id AS id, ' + NCHAR(13) + 
    N'       ''REMOTE_SERVICE_BINDING'' AS class_desc,' + NCHAR(13) + 
    N'       ''REMOTE SERVICE BINDING'' AS class ' + NCHAR(13) + 
    N'   FROM sys.remote_service_bindings' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       route_id AS id, ' + NCHAR(13) + 
    N'       ''ROUTE'' AS class_desc,' + NCHAR(13) + 
    N'       ''ROUTE'' AS class ' + NCHAR(13) + 
    N'   FROM sys.routes' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       fulltext_catalog_id AS id, ' + NCHAR(13) + 
    N'       ''FULLTEXT_CATALOG'' AS class_desc,' + NCHAR(13) + 
    N'       ''FULLTEXT CATALOG'' AS class ' + NCHAR(13) + 
    N'   FROM sys.fulltext_catalogs' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       symmetric_key_id AS id, ' + NCHAR(13) + 
    N'       ''SYMMETRIC_KEYS'' AS class_desc,' + NCHAR(13) + 
    N'       ''SYMMETRIC KEY'' AS class ' + NCHAR(13) + 
    N'   FROM sys.symmetric_keys' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       certificate_id AS id, ' + NCHAR(13) + 
    N'       ''CERTIFICATE'' AS class_desc,' + NCHAR(13) + 
    N'       ''CERTIFICATE'' AS class ' + NCHAR(13) + 
    N'   FROM sys.certificates' + NCHAR(13) + 
    N'   UNION ALL' + NCHAR(13) + 
    N'   SELECT NULL AS SchemaName, ' + NCHAR(13) + 
    N'       name ' + @Collation + N' AS name, ' + NCHAR(13) + 
    N'       asymmetric_key_id AS id, ' + NCHAR(13) + 
    N'       ''ASYMMETRIC_KEY'' AS class_desc,' + NCHAR(13) + 
    N'       ''ASYMMETRIC KEY'' AS class ' + NCHAR(13) + 
    N'   FROM sys.asymmetric_keys' + NCHAR(13) +  
    N'   ) ' + NCHAR(13)
  
    SET @sql =
    N'SELECT Grantee.principal_id AS GranteePrincipalId, Grantee.name AS GranteeName, Grantor.name AS GrantorName, ' + NCHAR(13) + 
    N'   Permission.class_desc, Permission.permission_name, ' + NCHAR(13) + 
    N'   ObjectList.name AS ObjectName, ' + NCHAR(13) + 
    N'   ObjectList.SchemaName, ' + NCHAR(13) + 
    N'   Permission.state_desc,  ' + NCHAR(13) + 
    N'   CASE WHEN Grantee.is_fixed_role = 0 AND Grantee.name <> ''dbo'' THEN ' + NCHAR(13) + 
    N'   ''REVOKE '' + ' + NCHAR(13) + 
    N'   CASE WHEN Permission.[state]  = ''W'' THEN ''GRANT OPTION FOR '' ELSE '''' END + ' + NCHAR(13) + 
    N'   '' '' + Permission.permission_name' + @Collation + N' +  ' + NCHAR(13) + 
    N'       CASE WHEN Permission.major_id <> 0 THEN '' ON '' + ' + NCHAR(13) + 
    N'           ObjectList.class + ''::'' +  ' + NCHAR(13) + 
    N'           ISNULL(QUOTENAME(ObjectList.SchemaName),'''') + ' + NCHAR(13) + 
    N'           CASE WHEN ObjectList.SchemaName + ObjectList.name IS NULL THEN '''' ELSE ''.'' END + ' + NCHAR(13) + 
    N'           ISNULL(QUOTENAME(ObjectList.name),'''') ' + NCHAR(13) + 
    N'           ' + @Collation + ' + '' '' ELSE '''' END + ' + NCHAR(13) + 
    N'       '' FROM '' + QUOTENAME(Grantee.name' + @Collation + N')  + ''; '' END AS RevokeScript, ' + NCHAR(13) + 
    N'   CASE WHEN Grantee.is_fixed_role = 0 AND Grantee.name <> ''dbo'' THEN ' + NCHAR(13) + 
    N'   CASE WHEN Permission.[state]  = ''W'' THEN ''GRANT'' ELSE Permission.state_desc' + @Collation + 
            N' END + ' + NCHAR(13) + 
    N'       '' '' + Permission.permission_name' + @Collation + N' + ' + NCHAR(13) + 
    N'       CASE WHEN Permission.major_id <> 0 THEN '' ON '' + ' + NCHAR(13) + 
    N'           ObjectList.class + ''::'' +  ' + NCHAR(13) + 
    N'           ISNULL(QUOTENAME(ObjectList.SchemaName),'''') + ' + NCHAR(13) + 
    N'           CASE WHEN ObjectList.SchemaName + ObjectList.name IS NULL THEN '''' ELSE ''.'' END + ' + NCHAR(13) + 
    N'           ISNULL(QUOTENAME(ObjectList.name),'''') ' + NCHAR(13) + 
    N'           ' + @Collation + N' + '' '' ELSE '''' END + ' + NCHAR(13) + 
    N'       '' TO '' + QUOTENAME(Grantee.name' + @Collation + N')  + '' '' +  ' + NCHAR(13) + 
    N'       CASE WHEN Permission.[state]  = ''W'' THEN '' WITH GRANT OPTION '' ELSE '''' END +  ' + NCHAR(13) + 
    N'       '' AS ''+ QUOTENAME(Grantor.name' + @Collation + N')+'';'' END AS GrantScript ' + NCHAR(13) + 
    N'FROM sys.database_permissions Permission ' + NCHAR(13) + 
    N'JOIN sys.database_principals Grantee ' + NCHAR(13) + 
    N'   ON Permission.grantee_principal_id = Grantee.principal_id ' + NCHAR(13) + 
    N'JOIN sys.database_principals Grantor ' + NCHAR(13) + 
    N'   ON Permission.grantor_principal_id = Grantor.principal_id ' + NCHAR(13) + 
    N'LEFT OUTER JOIN ObjectList ' + NCHAR(13) + 
    N'   ON Permission.major_id = ObjectList.id ' + NCHAR(13) + 
    N'   AND Permission.class_desc = ObjectList.class_desc ' + NCHAR(13) + 
    N'WHERE 1=1 '
    
IF LEN(ISNULL(@Principal,@Role)) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Grantee.name ' + @LikeOperator + N' ' + ISNULL(QUOTENAME(@Principal,''''),QUOTENAME(@Role,'''')) 
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Grantee.name ' + @LikeOperator + N' ISNULL(@Principal,@Role) '
            
IF LEN(@Type) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Grantee.type ' + @LikeOperator + N' ' + QUOTENAME(@Type,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Grantee.type ' + @LikeOperator + N' @Type'
    
IF LEN(@ObjectName) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND ObjectList.name ' + @LikeOperator + N' ' + QUOTENAME(@ObjectName,'''') 
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND ObjectList.name ' + @LikeOperator + N' @ObjectName '
    
IF LEN(@Permission) > 0
    IF @Print = 1
        SET @sql = @sql + NCHAR(13) + N'  AND Permission.permission_name ' + @LikeOperator + N' ' + QUOTENAME(@Permission,'''')
    ELSE
        SET @sql = @sql + NCHAR(13) + N'  AND Permission.permission_name ' + @LikeOperator + N' @Permission'

IF @IncludeMSShipped = 0
	SET @sql = @sql + NCHAR(13) + N'  AND Grantee.is_fixed_role = 0 ' + NCHAR(13) + 
				'  AND Grantee.name NOT IN (''dbo'',''public'',''INFORMATION_SCHEMA'',''guest'',''sys'') '
  
IF @Print = 1
    BEGIN
        PRINT '-- Database & object Permissions' 
        PRINT CAST(@ObjectList AS nvarchar(max))
        PRINT CAST(@sql AS nvarchar(max))
    END
ELSE
BEGIN
	IF object_id('tempdb..##DBPermissions') IS NOT NULL
		DROP TABLE ##DBPermissions

    -- Create temp table to store the data in
    CREATE TABLE ##DBPermissions (
        GranteePrincipalId int NULL,
		GranteeName sysname NULL,
        GrantorName sysname NULL,
        class_desc nvarchar(60) NULL,
        permission_name nvarchar(128) NULL,
        ObjectName sysname NULL,
        SchemaName sysname NULL,
        state_desc nvarchar(60) NULL,
        RevokeScript nvarchar(max) NULL,
        GrantScript nvarchar(max) NULL
        )
    
    -- Add insert statement to @sql
    SET @sql =  @ObjectList + 
                N'INSERT INTO ##DBPermissions ' + NCHAR(13) + 
                @sql

    EXEC sp_executesql @sql, N'@Principal sysname, @Role sysname, @Type nvarchar(30), 
        @ObjectName sysname, @Permission sysname', 
        @Principal, @Role, @Type, @ObjectName, @Permission
END

IF @Print <> 1
BEGIN
	IF @Output = 'None'
		PRINT ''
	ELSE IF @Output = 'CreateOnly'
	BEGIN
		SELECT CreateScript FROM ##DBPrincipals WHERE CreateScript IS NOT NULL
		UNION ALL
		SELECT AddScript FROM ##DBRoles WHERE AddScript IS NOT NULL
		UNION ALL
		SELECT GrantScript FROM ##DBPermissions WHERE GrantScript IS NOT NULL
	END 
	ELSE IF @Output = 'DropOnly' 
	BEGIN
		SELECT DropScript FROM ##DBPrincipals WHERE DropScript IS NOT NULL
		UNION ALL
		SELECT DropScript FROM ##DBRoles WHERE DropScript IS NOT NULL
		UNION ALL
		SELECT RevokeScript FROM ##DBPermissions WHERE RevokeScript IS NOT NULL
	END
	ELSE IF @Output = 'ScriptOnly' 
	BEGIN
		SELECT DropScript, CreateScript FROM ##DBPrincipals WHERE DropScript IS NOT NULL OR CreateScript IS NOT NULL
		UNION ALL
		SELECT DropScript, AddScript FROM ##DBRoles WHERE DropScript IS NOT NULL OR AddScript IS NOT NULL
		UNION ALL
		SELECT RevokeScript, GrantScript FROM ##DBPermissions WHERE RevokeScript IS NOT NULL OR GrantScript IS NOT NULL
	END
	ELSE IF @Output = 'Report'
	BEGIN
		SELECT DBPrincipal, type, type_desc,
				STUFF((SELECT ', ' + ##DBRoles.RoleName
						FROM ##DBRoles
						WHERE ##DBPrincipals.DBPrincipalId = ##DBRoles.UserPrincipalId
						ORDER BY ##DBRoles.RoleName
						FOR XML PATH(''),TYPE).value('.','VARCHAR(MAX)')
					, 1, 2, '') AS RoleMembership,
				STUFF((SELECT ', ' + ##DBPermissions.state_desc + ' ' + ##DBPermissions.permission_name + ' on ' + 
						COALESCE('OBJECT:'+##DBPermissions.SchemaName + '.' + ##DBPermissions.ObjectName, 
								'SCHEMA:'+##DBPermissions.SchemaName)
						FROM ##DBPermissions
						WHERE ##DBPrincipals.DBPrincipalId = ##DBPermissions.GranteePrincipalId
						ORDER BY ##DBPermissions.state_desc, ##DBPermissions.ObjectName, ##DBPermissions.permission_name
						FOR XML PATH(''),TYPE).value('.','VARCHAR(MAX)')
					, 1, 2, '') AS DirectPermissions
		FROM ##DBPrincipals
		ORDER BY type, DBPrincipal
	END
	ELSE -- 'Default' or no match
	BEGIN
		SELECT DBPrincipal, type, type_desc, default_schema_name, 
				create_date, modify_date, is_fixed_role, RoleAuthorization, sid, 
				DropScript, CreateScript
		FROM ##DBPrincipals ORDER BY DBPrincipal
		IF LEN(@Role) > 0
			SELECT UserName, RoleName, DropScript, AddScript 
			FROM ##DBRoles ORDER BY RoleName, UserName
		ELSE
			SELECT UserName, RoleName, DropScript, AddScript 
			FROM ##DBRoles ORDER BY UserName, RoleName

		IF LEN(@ObjectName) > 0
			SELECT GranteeName, GrantorName, class_desc, permission_name, ObjectName, 
				SchemaName, state_desc, RevokeScript, GrantScript 
			FROM ##DBPermissions ORDER BY ObjectName, GranteeName
		ELSE
			SELECT GranteeName, GrantorName, class_desc, permission_name, ObjectName, 
				SchemaName, state_desc, RevokeScript, GrantScript 
			FROM ##DBPermissions ORDER BY GranteeName, ObjectName
	END

	IF @DropTempTables = 1
	BEGIN
		DROP TABLE ##DBPrincipals
		DROP TABLE ##DBRoles
		DROP TABLE ##DBPermissions
	END
END
GO
