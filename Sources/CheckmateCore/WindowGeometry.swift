import Foundation
public enum WindowGeometry {
    public static func restored(_ values:[Double]?,screens:[CGRect],size:Double=780,minimum:Double=600)->CGRect {
        let screen=screens.first ?? CGRect(x:0,y:0,width:1440,height:900)
        let candidate: CGRect
        if let v=values,v.count==4,v.allSatisfy(\.isFinite),v[2]>0,v[3]>0 {candidate=CGRect(x:v[0],y:v[1],width:v[2],height:v[3])}else{candidate=CGRect(x:screen.midX-size/2,y:screen.midY-size/2,width:size,height:size)}
        let target=screens.max {a,b in a.intersection(candidate).width*a.intersection(candidate).height < b.intersection(candidate).width*b.intersection(candidate).height} ?? screen
        let width=min(target.width,max(minimum,candidate.width)),height=min(target.height,max(minimum,candidate.height))
        return CGRect(x:max(target.minX,min(target.maxX-width,candidate.minX)),y:max(target.minY,min(target.maxY-height,candidate.minY)),width:width,height:height)
    }
}
