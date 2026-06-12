/**
 * MapMetadataStore — 离线地图元数据 + 下载进度 SQLite 存储层
 *
 * 全静态方法，封装 @ohos.data.relationalStore 操作。
 *
 * 使用方式：
 *   await MapMetadataStore.init(context);
 *   await MapMetadataStore.insertOrUpdateMap(mapId, metadataJson, metadataUrl, downloadUrl);
 *   await MapMetadataStore.updateProgress(mapId, progress, downloadedSize, fileSize, status);
 *   const record = await MapMetadataStore.getMapMetadata(mapId);
 */

import relationalStore from '@ohos.data.relationalStore';
import common from '@ohos.app.ability.common';

const DB_NAME = 'harmonygis_maps.db';
const TABLE_NAME = 'map_metadata';

/** SQLite 行数据结构 */
export interface MapMetadataRecord {
  id: number;
  mapId: string;
  metadataJson: string;
  metadataUrl: string;
  downloadUrl: string;
  filePath: string;
  fileSize: number;
  downloadedSize: number;
  progress: number;
  status: number;
  createTime: number;
  updateTime: number;
}

export class MapMetadataStore {
  private static rdbStore: relationalStore.RdbStore | null = null;

  /**
   * 初始化数据库（打开/创建 + 建表）
   *
   * 必须在应用启动时调用一次，传入 UIAbilityContext。
   * 初始化失败不会抛异常，后续所有写入操作静默跳过。
   *
   * @param context 应用上下文（用于 getRdbStore 定位数据库目录）
   */
  static async init(context: common.Context): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      MapMetadataStore.rdbStore = await relationalStore.getRdbStore(context, config);

      // 建表（IF NOT EXISTS 保证幂等）
      await MapMetadataStore.rdbStore.executeSql(
        `CREATE TABLE IF NOT EXISTS ${TABLE_NAME} (` +
        'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
        'map_id TEXT NOT NULL UNIQUE, ' +
        'metadata_json TEXT DEFAULT \'{}\', ' +
        'metadata_url TEXT DEFAULT \'\', ' +
        'download_url TEXT DEFAULT \'\', ' +
        'file_path TEXT DEFAULT \'\', ' +
        'file_size INTEGER DEFAULT -1, ' +
        'downloaded_size INTEGER DEFAULT 0, ' +
        'progress INTEGER DEFAULT 0, ' +
        'status INTEGER DEFAULT 0, ' +
        'create_time INTEGER NOT NULL, ' +
        'update_time INTEGER NOT NULL' +
        ')'
      );

      console.info('[MapMetadataStore] 数据库初始化完成');
    } catch (err) {
      console.error(`[MapMetadataStore] 数据库初始化失败: ${JSON.stringify(err)}`);
      MapMetadataStore.rdbStore = null;
    }
  }

  /**
   * 数据库是否已成功初始化
   */
  static isInitialized(): boolean {
    return MapMetadataStore.rdbStore !== null;
  }

  /**
   * 插入或更新地图元数据（下载开始前调用）
   *
   * 先尝试 INSERT，如果 map_id 已存在则走 UPDATE。
   *
   * @param mapId 地图唯一标识
   * @param metadataJson 从 XML 解析并 JSON.stringify 后的元数据
   * @param metadataUrl 元数据请求地址
   * @param downloadUrl 地图包下载地址
   */
  static async insertOrUpdateMap(
    mapId: string,
    metadataJson: string,
    metadataUrl: string,
    downloadUrl: string
  ): Promise<void> {
    const store = MapMetadataStore.rdbStore;
    if (!store) {
      return;
    }

    const now = Date.now();

    try {
      const bucket: relationalStore.ValuesBucket = {
        'map_id': mapId,
        'metadata_json': metadataJson,
        'metadata_url': metadataUrl,
        'download_url': downloadUrl,
        'file_path': '',
        'file_size': -1,
        'downloaded_size': 0,
        'progress': 0,
        'status': 0,
        'create_time': now,
        'update_time': now
      };

      const rowId = await store.insert(TABLE_NAME, bucket);
      if (rowId <= 0) {
        // map_id 已存在，走更新
        const updateBucket: relationalStore.ValuesBucket = {
          'metadata_json': metadataJson,
          'metadata_url': metadataUrl,
          'download_url': downloadUrl,
          'update_time': now
        };
        const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
        predicates.equalTo('map_id', mapId);
        await store.update(updateBucket, predicates);
      }

      console.info(`[MapMetadataStore] insertOrUpdateMap: mapId=${mapId}`);
    } catch (err) {
      console.error(`[MapMetadataStore] insertOrUpdateMap 失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 更新下载进度（下载中每 1% 触发）
   *
   * fire-and-forget 调用，内部 catch 所有异常。
   *
   * @param mapId 地图唯一标识
   * @param progress 0-100
   * @param downloadedSize 已下载字节数
   * @param fileSize 总字节数（-1 表示未知）
   * @param status DownloadState 枚举值
   */
  static async updateProgress(
    mapId: string,
    progress: number,
    downloadedSize: number,
    fileSize: number,
    status: number
  ): Promise<void> {
    const store = MapMetadataStore.rdbStore;
    if (!store) {
      return;
    }

    try {
      const bucket: relationalStore.ValuesBucket = {
        'progress': progress,
        'downloaded_size': downloadedSize,
        'file_size': fileSize,
        'status': status,
        'update_time': Date.now()
      };
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.equalTo('map_id', mapId);
      await store.update(bucket, predicates);
    } catch (err) {
      console.error(`[MapMetadataStore] updateProgress 失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 更新下载完成信息（下载成功 + 解压完成后调用）
   *
   * @param mapId 地图唯一标识
   * @param filePath 文件/解压目录的本地绝对路径
   * @param fileSize 最终文件大小
   * @param downloadedSize 最终已下载大小（应等于 fileSize）
   * @param status 3 = COMPLETED
   */
  static async updateCompletion(
    mapId: string,
    filePath: string,
    fileSize: number,
    downloadedSize: number,
    status: number
  ): Promise<void> {
    const store = MapMetadataStore.rdbStore;
    if (!store) {
      return;
    }

    try {
      const bucket: relationalStore.ValuesBucket = {
        'file_path': filePath,
        'file_size': fileSize,
        'downloaded_size': downloadedSize,
        'progress': 100,
        'status': status,
        'update_time': Date.now()
      };
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.equalTo('map_id', mapId);
      await store.update(bucket, predicates);

      console.info(`[MapMetadataStore] updateCompletion: mapId=${mapId}, path=${filePath}`);
    } catch (err) {
      console.error(`[MapMetadataStore] updateCompletion 失败: ${JSON.stringify(err)}`);
    }
  }

  /**
   * 查询单条地图元数据
   *
   * @param mapId 地图唯一标识
   * @returns MapMetadataRecord 或 null
   */
  static async getMapMetadata(mapId: string): Promise<MapMetadataRecord | null> {
    const store = MapMetadataStore.rdbStore;
    if (!store) {
      return null;
    }

    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.equalTo('map_id', mapId);
      const resultSet = await store.query(predicates);

      if (resultSet.goToFirstRow()) {
        const record = MapMetadataStore.rowToRecord(resultSet);
        resultSet.close();
        return record;
      }
      resultSet.close();
      return null;
    } catch (err) {
      console.error(`[MapMetadataStore] getMapMetadata 失败: ${JSON.stringify(err)}`);
      return null;
    }
  }

  /**
   * 查询全部地图元数据
   *
   * @returns 按 update_time 倒序排列的记录列表
   */
  static async getAllMaps(): Promise<MapMetadataRecord[]> {
    const store = MapMetadataStore.rdbStore;
    if (!store) {
      return [];
    }

    try {
      const predicates = new relationalStore.RdbPredicates(TABLE_NAME);
      predicates.orderByDesc('update_time');
      const resultSet = await store.query(predicates);

      const records: MapMetadataRecord[] = [];
      if (resultSet.goToFirstRow()) {
        do {
          records.push(MapMetadataStore.rowToRecord(resultSet));
        } while (resultSet.goToNextRow());
      }
      resultSet.close();
      return records;
    } catch (err) {
      console.error(`[MapMetadataStore] getAllMaps 失败: ${JSON.stringify(err)}`);
      return [];
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════

  /**
   * 将 ResultSet 当前行转为 MapMetadataRecord
   */
  private static rowToRecord(resultSet: relationalStore.ResultSet): MapMetadataRecord {
    return {
      id: resultSet.getLong(resultSet.getColumnIndex('id')),
      mapId: resultSet.getString(resultSet.getColumnIndex('map_id')),
      metadataJson: resultSet.getString(resultSet.getColumnIndex('metadata_json')),
      metadataUrl: resultSet.getString(resultSet.getColumnIndex('metadata_url')),
      downloadUrl: resultSet.getString(resultSet.getColumnIndex('download_url')),
      filePath: resultSet.getString(resultSet.getColumnIndex('file_path')),
      fileSize: resultSet.getLong(resultSet.getColumnIndex('file_size')),
      downloadedSize: resultSet.getLong(resultSet.getColumnIndex('downloaded_size')),
      progress: resultSet.getLong(resultSet.getColumnIndex('progress')),
      status: resultSet.getLong(resultSet.getColumnIndex('status')),
      createTime: resultSet.getLong(resultSet.getColumnIndex('create_time')),
      updateTime: resultSet.getLong(resultSet.getColumnIndex('update_time'))
    };
  }
}
