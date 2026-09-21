using LanStash.Domain;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;

namespace LanStash.App.Views;

internal static class WorkspaceIcons
{
    // 固定几何资源不依赖设备安装的图标字体。坐标统一为 24 × 24。
    internal static PathIcon ForModule(AppModule module)
    {
        var path = module switch
        {
            AppModule.Files => "F0 M1,4 L9,4 L12,7 L23,7 L23,21 L1,21 Z M3,6 L3,19 L21,19 L21,9 L11,9 L8,6 Z",
            AppModule.Photos => "F0 M1,3 L23,3 L23,22 L1,22 Z M3,5 L3,17 L9,11 L14,16 L18,12 L21,15 L21,5 Z M14,7 A2,2 0 1 1 13.99,7 Z",
            AppModule.Chat => "F0 M3,2 L21,2 Q24,2 24,5 L24,17 Q24,20 21,20 L10,20 L4,24 L4,20 L3,20 Q0,20 0,17 L0,5 Q0,2 3,2 Z M3,4 Q2,4 2,5 L2,17 Q2,18 3,18 L6,18 L6,20 L10,18 L21,18 Q22,18 22,17 L22,5 Q22,4 21,4 Z M5,10 L7,10 L7,12 L5,12 Z M11,10 L13,10 L13,12 L11,12 Z M17,10 L19,10 L19,12 L17,12 Z",
            AppModule.Downloads => "M11,1 L13,1 L13,16 L19,10 L20.5,11.5 L12,20 L3.5,11.5 L5,10 L11,16 Z M3,22 L21,22 L21,24 L3,24 Z",
            AppModule.Containers => "F0 M12,0 L23,6 L23,18 L12,24 L1,18 L1,6 Z M3,7 L3,17 L11,21.5 L11,11.5 Z M13,11.5 L13,21.5 L21,17 L21,7 Z M4,5.5 L12,10 L20,5.5 L12,2 Z",
            AppModule.VirtualMachines => "F0 M1,2 L23,2 L23,19 L14,19 L14,22 L19,22 L19,24 L5,24 L5,22 L10,22 L10,19 L1,19 Z M3,4 L3,17 L21,17 L21,4 Z",
            AppModule.NasSettings => "F0 M1,2 L23,2 L23,22 L1,22 Z M3,4 L3,8 L21,8 L21,4 Z M3,10 L3,14 L21,14 L21,10 Z M3,16 L3,20 L21,20 L21,16 Z M17,5 L19,5 L19,7 L17,7 Z M17,11 L19,11 L19,13 L17,13 Z M17,17 L19,17 L19,19 L17,19 Z",
            _ => "M2,7 L17,7 L12,2 L13.5,0.5 L21,8 L13.5,15.5 L12,14 L17,9 L2,9 Z M22,17 L7,17 L12,22 L10.5,23.5 L3,16 L10.5,8.5 L12,10 L7,15 L22,15 Z",
        };
        var geometry = (Geometry)XamlBindingHelper.ConvertValue(typeof(Geometry), path);
        // PathIcon 按几何坐标绘制，不会把 24 单位路径自动缩进 22 单位视口。
        geometry.Transform = new ScaleTransform { ScaleX = 20d / 24, ScaleY = 20d / 24 };
        return new PathIcon
        {
            Data = geometry,
            Width = 22,
            Height = 22,
        };
    }
}
