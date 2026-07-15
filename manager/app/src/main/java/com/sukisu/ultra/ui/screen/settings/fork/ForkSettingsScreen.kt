package com.sukisu.ultra.ui.screen.settings.fork

import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.add
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Timer
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberTopAppBarState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import com.sukisu.ultra.R
import com.sukisu.ultra.data.repository.SettingsRepositoryImpl
import com.sukisu.ultra.ui.LocalUiMode
import com.sukisu.ultra.ui.UiMode
import com.sukisu.ultra.ui.component.material.ExpressiveScaffold
import com.sukisu.ultra.ui.component.material.SegmentedColumn
import com.sukisu.ultra.ui.component.material.SegmentedDropdownItem
import com.sukisu.ultra.ui.component.material.TopBarBackButton
import com.sukisu.ultra.ui.component.material.expressiveTopAppBarColors
import com.sukisu.ultra.ui.navigation3.LocalNavigator
import com.sukisu.ultra.ui.theme.LocalEnableBlur
import com.sukisu.ultra.ui.util.BlurredBar
import com.sukisu.ultra.ui.util.rememberBlurBackdrop
import top.yukonga.miuix.kmp.basic.Card
import top.yukonga.miuix.kmp.basic.IconButton
import top.yukonga.miuix.kmp.basic.MiuixScrollBehavior
import top.yukonga.miuix.kmp.basic.Scaffold
import top.yukonga.miuix.kmp.blur.layerBackdrop
import top.yukonga.miuix.kmp.icon.MiuixIcons
import top.yukonga.miuix.kmp.icon.extended.Back
import top.yukonga.miuix.kmp.preference.OverlayDropdownPreference
import top.yukonga.miuix.kmp.theme.MiuixTheme.colorScheme
import top.yukonga.miuix.kmp.utils.overScrollVertical
import top.yukonga.miuix.kmp.utils.scrollEndHaptic

private val actionTimeoutValues = listOf(30L, 60L, 120L, 0L)

@Composable
fun ForkSettingsScreen() {
    val navigator = LocalNavigator.current
    val repository = remember { SettingsRepositoryImpl() }
    var selectedTimeout by remember { mutableLongStateOf(repository.moduleActionTimeoutSeconds) }
    val timeoutLabels = listOf(
        stringResource(R.string.module_action_timeout_30_seconds),
        stringResource(R.string.module_action_timeout_60_seconds),
        stringResource(R.string.module_action_timeout_120_seconds),
        stringResource(R.string.module_action_timeout_infinity),
    )
    val selectedIndex = actionTimeoutValues.indexOf(selectedTimeout).coerceAtLeast(0)
    val onTimeoutSelected: (Int) -> Unit = { index ->
        actionTimeoutValues.getOrNull(index)?.let { timeout ->
            repository.moduleActionTimeoutSeconds = timeout
            selectedTimeout = timeout
        }
    }

    when (LocalUiMode.current) {
        UiMode.Material -> ForkSettingsMaterial(
            timeoutLabels = timeoutLabels,
            selectedIndex = selectedIndex,
            onTimeoutSelected = onTimeoutSelected,
            onBack = navigator::pop,
        )

        UiMode.Miuix -> ForkSettingsMiuix(
            timeoutLabels = timeoutLabels,
            selectedIndex = selectedIndex,
            onTimeoutSelected = onTimeoutSelected,
            onBack = navigator::pop,
        )
    }
}

@Composable
private fun ForkSettingsMaterial(
    timeoutLabels: List<String>,
    selectedIndex: Int,
    onTimeoutSelected: (Int) -> Unit,
    onBack: () -> Unit,
) {
    val scrollBehavior = TopAppBarDefaults.pinnedScrollBehavior(rememberTopAppBarState())

    ExpressiveScaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.fork_settings)) },
                navigationIcon = { TopBarBackButton(onClick = onBack) },
                scrollBehavior = scrollBehavior,
                colors = expressiveTopAppBarColors(),
            )
        },
        contentWindowInsets = WindowInsets.systemBars.add(WindowInsets.displayCutout)
            .only(WindowInsetsSides.Horizontal),
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxHeight()
                .nestedScroll(scrollBehavior.nestedScrollConnection)
                .padding(horizontal = 16.dp),
            contentPadding = innerPadding,
        ) {
            item {
                SegmentedColumn(
                    modifier = Modifier.padding(top = 12.dp),
                    content = listOf {
                        SegmentedDropdownItem(
                            icon = Icons.Rounded.Timer,
                            title = stringResource(R.string.module_action_timeout),
                            summary = stringResource(R.string.module_action_timeout_summary),
                            items = timeoutLabels,
                            selectedIndex = selectedIndex,
                            onItemSelected = onTimeoutSelected,
                        )
                    },
                )
            }
        }
    }
}

@Composable
private fun ForkSettingsMiuix(
    timeoutLabels: List<String>,
    selectedIndex: Int,
    onTimeoutSelected: (Int) -> Unit,
    onBack: () -> Unit,
) {
    val scrollBehavior = MiuixScrollBehavior()
    val backdrop = rememberBlurBackdrop(LocalEnableBlur.current)
    val barColor = if (backdrop != null) Color.Transparent else colorScheme.surface

    Scaffold(
        topBar = {
            BlurredBar(backdrop) {
                top.yukonga.miuix.kmp.basic.TopAppBar(
                    color = barColor,
                    title = stringResource(R.string.fork_settings),
                    scrollBehavior = scrollBehavior,
                    navigationIcon = {
                        IconButton(onClick = onBack) {
                            val layoutDirection = LocalLayoutDirection.current
                            top.yukonga.miuix.kmp.basic.Icon(
                                modifier = Modifier.graphicsLayer {
                                    if (layoutDirection == LayoutDirection.Rtl) scaleX = -1f
                                },
                                imageVector = MiuixIcons.Back,
                                contentDescription = null,
                            )
                        }
                    },
                )
            }
        },
        popupHost = { },
        contentWindowInsets = WindowInsets.systemBars.add(WindowInsets.displayCutout)
            .only(WindowInsetsSides.Horizontal),
    ) { innerPadding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxHeight()
                .scrollEndHaptic()
                .overScrollVertical()
                .nestedScroll(scrollBehavior.nestedScrollConnection)
                .padding(horizontal = 12.dp)
                .let { modifier ->
                    if (backdrop != null) modifier.layerBackdrop(backdrop) else modifier
                },
            contentPadding = innerPadding,
            overscrollEffect = null,
        ) {
            item {
                Card(
                    modifier = Modifier
                        .padding(top = 12.dp)
                        .fillMaxWidth(),
                ) {
                    OverlayDropdownPreference(
                        title = stringResource(R.string.module_action_timeout),
                        summary = stringResource(R.string.module_action_timeout_summary),
                        items = timeoutLabels,
                        startAction = {
                            top.yukonga.miuix.kmp.basic.Icon(
                                Icons.Rounded.Timer,
                                modifier = Modifier.padding(end = 6.dp),
                                contentDescription = null,
                                tint = colorScheme.onBackground,
                            )
                        },
                        selectedIndex = selectedIndex,
                        onSelectedIndexChange = onTimeoutSelected,
                    )
                }
            }
        }
    }
}
