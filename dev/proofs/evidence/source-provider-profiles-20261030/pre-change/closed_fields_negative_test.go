package routing
import (
    "testing"
    "encoding/json"
    "crypto/sha256"
    "encoding/hex"
    v1 "github.com/HardenedLinux/weaver/go/api/v1"
)
func TestUnregisteredCapAliasMustNotPassOriginalSourceBinding(t *testing.T){
    task,plan:=providerOriginal(t)
    body,err:=v1.Decode[map[string]json.RawMessage]([]byte(plan.Body));if err!=nil{t.Fatal(err)}
    body["max_output_tokens"]=[]byte(`1000000`)
    data,err:=json.Marshal(body);if err!=nil{t.Fatal(err)};plan.Body=string(data)
    sum:=sha256.Sum256(data);task.BodyDigests[plan.Node]=hex.EncodeToString(sum[:])
    digest,err:=plan.Digest();if err!=nil{t.Fatal(err)};task.StreamContracts[plan.Node]=digest
    if _,err:=CompileProvider(task,plan,v1.View{});err==nil{t.Fatal("unregistered extension accepted under an exact source commitment")}
}
