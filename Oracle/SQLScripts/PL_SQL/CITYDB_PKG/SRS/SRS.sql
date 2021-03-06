-- 3D City Database - The Open Source CityGML Database
-- http://www.3dcitydb.org/
-- 
-- Copyright 2013 - 2018
-- Chair of Geoinformatics
-- Technical University of Munich, Germany
-- https://www.gis.bgu.tum.de/
-- 
-- The 3D City Database is jointly developed with the following
-- cooperation partners:
-- 
-- virtualcitySYSTEMS GmbH, Berlin <http://www.virtualcitysystems.de/>
-- M.O.S.S. Computer Grafik Systeme GmbH, Taufkirchen <http://www.moss.de/>
-- 
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
-- 
--     http://www.apache.org/licenses/LICENSE-2.0
--     
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

/*****************************************************************
* PACKAGE citydb_util
* 
* utility methods for spatial reference system in the database
******************************************************************/
CREATE OR REPLACE PACKAGE citydb_srs
AS
  FUNCTION transform_or_null(geom MDSYS.SDO_GEOMETRY, srid NUMBER) RETURN MDSYS.SDO_GEOMETRY;
  FUNCTION is_coord_ref_sys_3d(schema_srid NUMBER) RETURN NUMBER;
  FUNCTION check_srid(srsno INTEGER := 0) RETURN VARCHAR;
  FUNCTION is_db_coord_ref_sys_3d(schema_name VARCHAR2 := USER) RETURN NUMBER;
  FUNCTION get_dim(col_name VARCHAR2, tab_name VARCHAR2, schema_name VARCHAR2 := USER) RETURN NUMBER;
  PROCEDURE change_column_srid(tab_name VARCHAR2, col_name VARCHAR2, dim NUMBER, schema_srid NUMBER, transform NUMBER := 0, schema_name VARCHAR2 := USER);
  PROCEDURE change_schema_srid(schema_srid NUMBER, schema_gml_srs_name VARCHAR2, transform NUMBER := 0, schema_name VARCHAR2 := USER);
  PROCEDURE sync_spatial_metadata;
END citydb_srs;
/

CREATE OR REPLACE PACKAGE BODY citydb_srs
AS
  /*****************************************************************
  * transform_or_null
  *
  * @param geom the geometry whose representation is to be transformed using another coordinate system 
  * @param srid the SRID of the coordinate system to be used for the transformation.
  * @return MDSYS.SDO_GEOMETRY the transformed geometry representation                
  ******************************************************************/
  FUNCTION transform_or_null(geom MDSYS.SDO_GEOMETRY, srid NUMBER)
    RETURN MDSYS.SDO_GEOMETRY
  IS
  BEGIN
    IF geom IS NOT NULL THEN
      RETURN sdo_cs.transform(geom, srid);
    ELSE
      RETURN NULL;
    END IF;
  END;

  /*****************************************************************
  * is_coord_ref_sys_3d
  *
  * @param srid the SRID of the coordinate system to be checked
  * @return NUMBER the boolean result encoded as number: 0 = false, 1 = true                
  ******************************************************************/
  FUNCTION is_coord_ref_sys_3d(schema_srid NUMBER)
    RETURN NUMBER
  IS
    is_3d NUMBER := 0;
  BEGIN
    SELECT COALESCE((
      SELECT 1 FROM sdo_crs_compound WHERE srid = schema_srid
      ),(
      SELECT 1 FROM sdo_crs_geographic3d WHERE srid = schema_srid
      ), 0)
    INTO is_3d FROM dual;

    RETURN is_3d;
  END;

  /*******************************************************************
  * check_srid
  *
  * @param srsno     the chosen SRID to be further used in the database
  *
  * @RETURN VARCHAR  status of srid check
  *******************************************************************/
  FUNCTION check_srid(srsno INTEGER DEFAULT 0)
    RETURN VARCHAR
  IS
    schema_srid INTEGER;
    unknown_srs_ex EXCEPTION;
  BEGIN
    SELECT COUNT(srid) INTO schema_srid FROM mdsys.cs_srs WHERE srid = srsno;

    IF schema_srid = 0 THEN
      RAISE unknown_srs_ex;
    END IF;

    RETURN 'SRID ok';

    EXCEPTION
      WHEN unknown_srs_ex THEN
        dbms_output.put_line('Table MDSYS.CS_SRS does not contain the SRID ' || srsno);
        RETURN 'SRID not ok';
  END;

  /*****************************************************************
  * is_db_coord_ref_sys_3d
  *
  * @return NUMBER the boolean result encoded as number: 0 = false, 1 = true                
  ******************************************************************/
  FUNCTION is_db_coord_ref_sys_3d(schema_name VARCHAR2 := USER)
    RETURN NUMBER
  IS
    schema_srid NUMBER;
  BEGIN
    EXECUTE IMMEDIATE
      'SELECT srid FROM '||schema_name||'.database_srs'
      INTO schema_srid;
    RETURN is_coord_ref_sys_3d(schema_srid);
  END;

  /*****************************************************************
  * get_dim
  *
  * @param col_name name of the column
  * @param tab_name name of the table
  * @param schema_name name of schema
  * @RETURN NUMBER number of dimension
  ******************************************************************/
  FUNCTION get_dim(
    col_name VARCHAR2,
    tab_name VARCHAR2,
    schema_name VARCHAR2 := USER
    ) RETURN NUMBER
  IS
    is_3d NUMBER(1, 0);
  BEGIN
    SELECT
      3
    INTO
      is_3d
    FROM
      all_sdo_geom_metadata m,
      TABLE(m.diminfo) dim
    WHERE
      m.table_name = upper(tab_name)
      AND m.column_name = upper(col_name)
      AND dim.sdo_dimname = 'Z'
      AND m.owner = upper(schema_name);

    RETURN is_3d;

    EXCEPTION
      WHEN NO_DATA_FOUND THEN
        RETURN 2;
  END;

  /*****************************************************************
  * change_column_srid
  *
  * @param tab_name name of the table
  * @param col_name name of the column
  * @param dim dimension of spatial index
  * @param schema_srid the SRID of the coordinate system to be further used in the database
  * @param transform 1 if existing data shall be transformed, 0 if not
  * @param schema_name name of schema
  ******************************************************************/
  PROCEDURE change_column_srid(
    tab_name VARCHAR2,
    col_name VARCHAR2,
    dim NUMBER,
    schema_srid NUMBER,
    transform NUMBER := 0,
    schema_name VARCHAR2 := USER
  )
  IS
    internal_tab_name VARCHAR2(30);
    is_versioned BOOLEAN := FALSE;
    is_valid BOOLEAN;
    idx_name VARCHAR2(30);
    idx INDEX_OBJ;
    sql_err_code VARCHAR2(20);
  BEGIN
    IF tab_name LIKE '%\_LT' ESCAPE '\' THEN
      is_versioned := TRUE;
      internal_tab_name := substr(tab_name, 1, length(tab_name) - 3);
    ELSE
      internal_tab_name := tab_name;
    END IF;

    is_valid := citydb_idx.index_status(tab_name, col_name, schema_name) = 'VALID';

    -- update metadata as the index was switched off before transaction
    IF schema_name = USER THEN
      UPDATE
        user_sdo_geom_metadata
      SET
        srid = schema_srid
      WHERE
        table_name = upper(tab_name)
        AND column_name = upper(col_name);
    ELSE
      dbms_output.put_line('Did not update user_sdo_geom_metadata view for ' || schema_name || '. This user needs to call citydb_srs.sync_spatial_metadata procedure.');
    END IF;
    COMMIT;

    -- get name of spatial index
    BEGIN
      SELECT
        index_name
      INTO
        idx_name
      FROM
        all_ind_columns
      WHERE
        table_name = upper(tab_name)
        AND column_name = upper(col_name)
        AND index_owner = upper(schema_name);

      -- create INDEX_OBJ
      IF dim = 3 THEN
        idx := INDEX_OBJ.construct_spatial_3d(idx_name, internal_tab_name, col_name);
      ELSE
        idx := INDEX_OBJ.construct_spatial_2d(idx_name, internal_tab_name, col_name);
      END IF;

      -- drop spatial index
      sql_err_code := citydb_idx.drop_index(idx, is_versioned, schema_name);

      EXCEPTION
        WHEN NO_DATA_FOUND THEN
          is_valid := FALSE;
    END;

    IF transform <> 0 THEN
      -- coordinates of existent geometries will be transformed
      EXECUTE IMMEDIATE
        'UPDATE ' || schema_name || '.' || tab_name || ' SET ' || col_name || ' = sdo_cs.transform( ' || col_name || ', :1) WHERE ' || col_name || ' IS NOT NULL'
        USING schema_srid;
    ELSE
      -- only srid paramter of geometries is updated
      EXECUTE IMMEDIATE
        'UPDATE ' || schema_name || '.' || tab_name || ' t SET t.' || col_name || '.SDO_SRID = :1 WHERE t.' || col_name || ' IS NOT NULL'
        USING schema_srid;
    END IF;

    IF is_valid THEN
      -- create spatial index (incl. new spatial metadata)
      sql_err_code := citydb_idx.create_index(idx, is_versioned, schema_name);
    END IF;
  END;

  /*****************************************************************
  * change_schema_srid
  *
  * @param schema_srid the SRID of the coordinate system to be further used in the database
  * @param schema_gml_srs_name the GML_SRS_NAME of the coordinate system to be further used in the database
  * @param transform 1 if existing data shall be transformed, 0 if not
  * @param schema_name name of schema
  ******************************************************************/
  PROCEDURE change_schema_srid(
    schema_srid NUMBER,
    schema_gml_srs_name VARCHAR2,
    transform NUMBER := 0,
    schema_name VARCHAR2 := USER
  )
  IS
    unknown_srs_ex EXCEPTION;
  BEGIN
    IF citydb_srs.check_srid(schema_srid) <> 'SRID ok' THEN
      dbms_output.put_line('Your chosen SRID was not found in the MDSYS.CS_SRS table! Chosen SRID was ' || schema_srid);
    ELSE
      -- update entry in DATABASE_SRS table first
      EXECUTE IMMEDIATE
        'UPDATE '|| schema_name ||'.database_srs SET srid = :1, gml_srs_name = :2'
           USING schema_srid, schema_gml_srs_name;
      COMMIT;

      -- change srid of each spatially enabled table
      FOR rec IN (
        SELECT
          table_name AS t,
          column_name AS c,
          get_dim(column_name, table_name, schema_name) AS dim
        FROM
          all_sdo_geom_metadata
        WHERE
          owner = upper(schema_name)
        ) 
	  LOOP
        change_column_srid(rec.t, rec.c, rec.dim, schema_srid, transform, schema_name);
      END LOOP;
      dbms_output.put_line('Schema SRID sucessfully changed to ' || schema_srid);
    END IF;
  END;

  /*****************************************************************
  * sync_spatial_metadata
  *
  *****************************************************************/
  PROCEDURE sync_spatial_metadata
  IS
    schema_srid NUMBER;
  BEGIN
    -- fetch SRID in user schema
    SELECT
      srid
    INTO
      schema_srid
    FROM
      database_srs;

    -- update metadata if out of sync
    UPDATE
      user_sdo_geom_metadata
    SET
      srid = schema_srid
    WHERE
      srid <> schema_srid;
  END;

END citydb_srs;
/