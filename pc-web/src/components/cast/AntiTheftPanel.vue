<template>
  <div class="mt-8 pt-6 border-t border-gray-100">
    <h3 class="text-lg font-semibold mb-1">设备防盗与定位</h3>
    <p class="text-xs text-gray-400 mb-4">
      仅可向已配对设备下发指令；手机端会常驻通知并随时可停止。
    </p>

    <!-- 无配对设备 -->
    <div
      v-if="!targetUuid"
      class="text-center py-6 text-gray-400 text-sm border rounded-lg bg-surface-50"
    >
      暂无已配对设备，请先在上方完成绑定
    </div>

    <template v-else>
      <!-- 操作按钮 -->
      <div class="flex flex-wrap gap-2 mb-4">
        <button
          @click="onStartAlarm"
          class="px-3 py-1.5 text-sm rounded-lg bg-orange-500 hover:bg-orange-600 text-white transition-colors"
        >
          呼叫响铃
        </button>
        <button
          @click="onStopAlarm"
          class="px-3 py-1.5 text-sm rounded-lg border border-gray-200 hover:bg-gray-50 text-gray-700 transition-colors"
        >
          停止响铃
        </button>
        <button
          @click="onToggleTracking"
          :class="[
            'px-3 py-1.5 text-sm rounded-lg transition-colors',
            tracking
              ? 'bg-red-500 hover:bg-red-600 text-white'
              : 'bg-primary-600 hover:bg-primary-700 text-white',
          ]"
        >
          {{ tracking ? '停止定位' : '开始定位' }}
        </button>
      </div>

      <!-- 坐标卡片 -->
      <div class="rounded-lg border border-gray-200 p-3 bg-white">
        <div class="flex items-center justify-between mb-1">
          <span class="text-xs text-gray-500">最近坐标</span>
          <span
            v-if="tracking"
            class="text-xs text-green-600 flex items-center gap-1"
          >
            <span class="w-1.5 h-1.5 rounded-full bg-green-500"></span>共享中
          </span>
        </div>

        <template v-if="hasLocation">
          <div class="text-sm text-gray-800 font-mono">
            {{ lat.toFixed(6) }}, {{ lng.toFixed(6) }}
          </div>
          <div class="text-xs text-gray-400 mt-1">
            精度 ±{{ accuracyText }} m · 上报于 {{ timeText }}
          </div>

          <!-- 嵌入式地图：实时显示手机位置（Leaflet + OSM，无需 Key） -->
          <div
            ref="mapEl"
            class="mt-2 rounded-lg overflow-hidden border border-gray-100"
            style="height: 220px"
          ></div>

          <a
            :href="mapUrl"
            target="_blank"
            rel="noopener"
            class="inline-block mt-2 text-xs text-primary-600 hover:underline"
          >
            在高德地图中查看 →
          </a>
        </template>
        <div v-else class="text-sm text-gray-400 py-2">
          {{ tracking ? '等待手机上报坐标…' : '尚未获取坐标，点击「开始定位」' }}
        </div>
      </div>

      <!-- 执行回执 -->
      <div
        v-if="lastAck"
        class="mt-3 text-xs px-2 py-1.5 rounded"
        :class="lastAck.success ? 'bg-green-50 text-green-700' : 'bg-red-50 text-red-600'"
      >
        手机回执：{{ lastAck.message }}
      </div>
    </template>
  </div>
</template>

<script setup>
import { computed, inject, ref, watch, nextTick, onMounted, onBeforeUnmount } from 'vue'
import L from 'leaflet'
import 'leaflet/dist/leaflet.css'
import { useDeviceStore } from '../../stores/device'
import { useAntiTheft } from '../../composables/useAntiTheft'

const deviceStore = useDeviceStore()
const { latestLocation, lastAck, tracking, startAlarm, stopAlarm, startTracking, stopTracking } =
  useAntiTheft()
const showToast = inject('showToast', () => {})

/** 当前操作的已配对设备（取第一个） */
const targetUuid = computed(() => {
  const d = deviceStore.pairedDevices[0]
  return d ? d.uuid || d.id || d.deviceUuid : ''
})

const hasLocation = computed(() => {
  const loc = latestLocation.value
  return loc && typeof loc.latitude === 'number' && typeof loc.longitude === 'number'
})
const lat = computed(() => latestLocation.value?.latitude ?? 0)
const lng = computed(() => latestLocation.value?.longitude ?? 0)
const accuracyText = computed(() => {
  const a = latestLocation.value?.accuracy
  return typeof a === 'number' ? a.toFixed(1) : '—'
})
const timeText = computed(() => {
  const t = latestLocation.value?.receivedAt || latestLocation.value?.timestamp
  if (!t) return '—'
  return new Date(t).toLocaleTimeString('zh-CN')
})
// 高德地图 marker 链接（国内可达，无需 Key）；position 为 经度,纬度
const mapUrl = computed(
  () =>
    `https://uri.amap.com/marker?position=${lng.value},${lat.value}` +
    `&name=${encodeURIComponent('手机位置')}&src=ai-cast-hub&coordinate=gaode&callnative=0`,
)

// ---- Leaflet 地图 ----
const mapEl = ref(null)
let map = null
let marker = null

function ensureMap() {
  if (!mapEl.value) return
  if (!map) {
    map = L.map(mapEl.value, { zoomControl: true }).setView([lat.value, lng.value], 15)
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '© OpenStreetMap',
    }).addTo(map)
    // 用 circleMarker 避免默认图标资源在打包后 404 的问题
    marker = L.circleMarker([lat.value, lng.value], {
      radius: 8,
      color: '#ef4444',
      fillColor: '#ef4444',
      fillOpacity: 1,
      weight: 2,
    }).addTo(map)
    nextTick(() => map && map.invalidateSize())
  } else {
    map.setView([lat.value, lng.value], 15)
    marker.setLatLng([lat.value, lng.value])
  }
}

watch(
  () => latestLocation.value,
  (loc) => {
    if (loc && typeof loc.latitude === 'number') nextTick(ensureMap)
  },
)

onMounted(() => {
  if (hasLocation.value) nextTick(ensureMap)
})

onBeforeUnmount(() => {
  if (map) {
    map.remove()
    map = null
    marker = null
  }
})

function onStartAlarm() {
  startAlarm(targetUuid.value)
  showToast('已下发响铃指令，手机端可随时停止', 'info')
}
function onStopAlarm() {
  stopAlarm(targetUuid.value)
  showToast('已下发停止响铃指令', 'info')
}
function onToggleTracking() {
  if (tracking.value) {
    stopTracking(targetUuid.value)
    showToast('已停止位置共享', 'info')
  } else {
    startTracking(targetUuid.value)
    showToast('已请求位置共享，等待手机授权并上报', 'info')
  }
}
</script>
